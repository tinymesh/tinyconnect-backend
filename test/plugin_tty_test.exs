defmodule PluginTTYTest do
  use ExUnit.Case, async: false

  import Mock

  @nidev <<35,1,0,0,10,16,0,0,0,0,0,0,0,2,0,0,2,18,0,0,0,0,0,29,159,114,255,0,0,0,0,2,0,1,69>>

  test "serial test", %{test: name} do
    path = "/dev/vtty0"
    ret = {ref, parent} = {make_ref, self()}

    with_mock :gen_serial, [
        open: fn(path2, opts) ->
                send parent, {ref, :open, path2, opts}
                {:ok, ref}
              end,
        bsend: fn(ref, buf, _timeout) ->
          send parent, {ref, :send, buf}; :ok
        end,
        close: fn(_ref, _timeout) ->
          send parent, {ref, :close}
          :ok
        end
    ] do
      {:ok, manager} = :channel_manager.start_link name
      chan = "plugin-uart-#{name}"

      plugins = [
        {:tinyconnect_tty, %{name: plugin = "uart", parent: ret, port: {:path, path}}}
      ]

      :ok = :pg2.create [chan, plugin]
      :ok = :pg2.join [chan, plugin], self

      assert :ok = :channel_manager.add %{channel: chan, plugins: plugins}, manager

      # startup
      assert_receive {^ref, :open, ^path, _}
      {_,_, %{pid: pid}} = assert_receive {:'$tinyconnect', [^chan, ^plugin], %{type: :open}}
      assert_receive {^ref, :send, <<0>>}

      :tinyconnect_tty.send pid, cmd = <<10,0,0,0,0,0,3,16,0,0>>
      assert_receive {^ref, :send,[^cmd]}
      send pid, {:serial, ref, @nidev}

      assert_receive {:"$tinyconnect", [^chan, ^plugin], %{mode: :protocol, 
                                                           data: @nidev}}
    end
  end

  test "handle config mode", %{test: name} do
    path = "/dev/vtty0"
    ret = {ref, parent} = {make_ref, self()}

    with_mock :gen_serial, [
        open: fn(path2, opts) -> {:ok, ref} end,
        bsend: fn(ref, buf, _timeout) -> send parent, {ref, :send, buf}; :ok end,
        close: fn(_ref, _timeout) -> :ok end
    ] do
      {:ok, manager} = :channel_manager.start_link name
      chan = "plugin-uart-#{name}"

      plugins = [
        {:tinyconnect_tty, %{name: plugin = "uart", port: {:path, path}}}
      ]

      :ok = :pg2.create [chan, plugin]
      :ok = :pg2.join [chan, plugin], self

      assert :ok = :channel_manager.add %{channel: chan, plugins: plugins}, manager

      # startup
      {_,_, %{pid: pid}} = assert_receive {:'$tinyconnect', [^chan, ^plugin], %{type: :open}}
      assert_receive {^ref, :send, <<0>>}

      send pid, {:serial, ref, <<">">>}
      #this is now in init/..
      #assert_receive {:"$tinyconnect", [^chan, ^plugin], %{mode: :config, 
      #                                                     data: <<">">>}}
      # voltage reading or whatever
      send pid, {:serial, ref, <<33>>}
      send pid, {:serial, ref, <<">">>}
      assert_receive {:"$tinyconnect", [^chan, ^plugin], %{mode: :config, 
                                                           data: <<33>>}}
      assert_receive {:"$tinyconnect", [^chan, ^plugin], %{mode: :config, 
                                                           data: <<">">>}}

      # break on through to the other side!
      send pid, {:serial, ref, @nidev}

      assert_receive {:"$tinyconnect", [^chan, ^plugin], %{mode: :protocol, 
                                                           data: @nidev}}
    end
  end

  test "an ack here, and ack there - wait_for_ack", %{test: name} do
    path = "/dev/vtty0"
    ret = {ref, parent} = {make_ref, self()}

    with_mock :gen_serial, [
        open: fn(path2, opts) -> {:ok, ref} end,
        bsend: fn(ref, buf, _timeout) -> send parent, {ref, :send, buf}; :ok end,
        close: fn(_ref, _timeout) -> :ok end
    ] do
      {:ok, manager} = :channel_manager.start_link name
      chan = "plugin-uart-#{name}"

      plugins = [
        {:tinyconnect_tty, %{name: plugin = "uart", parent: ret, port: {:path, path}}}
      ]

      :ok = :pg2.create [chan, plugin]
      :ok = :pg2.join [chan, plugin], self

      assert :ok = :channel_manager.add %{channel: chan, plugins: plugins}, manager

      # startup
      {_,_, %{pid: pid}} = assert_receive {:'$tinyconnect', [^chan, ^plugin], %{type: :open}}
      assert_receive {^ref, :send, <<0>>}

      # this consistently takes 100ms!??!?!?! increase timeout
      assert_receive {^ref, :send, <<10, 0, 0, 0, 0, 0, 3, 16, 0, 0>>}, 200
      send pid, {:serial, ref, @nidev}
      assert_receive {:"$tinyconnect", [^chan, ^plugin], %{mode: :protocol, 
                                                           data: @nidev}}
      assert_receive {^ref, :send,<<6>>}
    end
  end

#  test "auto-refresh uart ports" do
#    alias :tinyconnect_handler_uart, as: UART
#
#    {:ok, server} = UART.start_link name = :'auto-refresh-test'
#    :ok =  :pg2.join name, self
#
#    setports ports = ["/dev/vtty0"]
#
#    assert :ok = UART.rescan server
#
#    setports _newports = ["/dev/vtty1" | ports]
#    assert :ok = UART.rescan server
#
#    added   = ["#{name}", "added"]
#    removed = ["#{name}", "removed"]
#
#    assert_receive {:"$tinyconnect", ^added, :vtty0}
#    assert_receive {:"$tinyconnect", ^added, :vtty1}
#
#    setports _ports = ["/dev/vtty0"]
#    assert :ok = UART.rescan server
#    assert_receive {:"$tinyconnect", ^removed, :vtty1}
#
#    assert :ok = :gen_server.call server, :stop
#  end
#
#  test "serial communications" do
#    alias :tinyconnect_handler_uart, as: UART
#
#    {parent, ref} = {self, make_ref}
#    with_mock :gen_serial, [
#        open: fn(_path2, _opts) -> {:ok, ref} end,
#        bsend: fn(ref, [buf], _timeout) -> send parent, {ref, :send, buf}; :ok end,
#        close: fn(_ref, _timeout) ->
#          send parent, {ref, :close}
#          :ok
#        end
#    ] do
#
#      {:ok, server} = UART.start_link name = :'serial-communications-test'
#      setports ["/dev/vtty0"]
#      assert :ok = UART.rescan server
#
#      assert {:error, {:notfound, {:worker, :vtty0}}} = UART.worker :vtty0, server
#
#      :ok =  :pg2.join name, self
#
#      assert :ok = UART.open :vtty0, server
#
#      {:ok, {:vtty0, tty}} = UART.worker :vtty0, server
#
#      ev = ["#{name}", "open"]
#      assert_receive {:'$tinyconnect', ^ev, %{id: :vtty0}}
#
#      send tty, {:serial, ref, recvd = <<35,1,0,0,0,1,0,0,0,0,0,0,0,2,0,0,2,18,0,0,0,0,0,1,126,115,255,0,0,0,0,2,0,1, 56>>}
#
#      ev = ["#{name}", "data"]
#      assert_receive {:'$tinyconnect', ^ev, %{data: ^recvd, id: :vtty0}}
#
#      monitor = Process.monitor tty
#      assert :ok = UART.close :vtty0, server
#
#      ev = ["#{name}", "close"]
#      assert_receive {:'$tinyconnect', ^ev, %{id: :vtty0}}
#      assert_receive {:DOWN, ^monitor, :process, ^tty, :normal}
#    end
#  end
#
#  test "send ack when stored in queue" do
#    alias :tinyconnect_handler_uart, as: UART
#    alias :tinyconnect_handler_queue, as: Queue
#
#    {parent, ref} = {self, make_ref}
#    with_mock :gen_serial, [
#        open: fn(_path2, _opts) -> {:ok, ref} end,
#        bsend: fn(ref, [buf], _timeout) -> send parent, {ref, :send, buf}; :ok end,
#        close: fn(_ref, _timeout) ->
#          send parent, {ref, :close}
#          :ok
#        end
#    ] do
#
#      uname = :'ack-uart-test'
#      qname = :'ack-queue-test'
#
#      {:ok, uart} = UART.start_link   uname, subscribe: [qname]
#      {:ok, queue} = Queue.start_link qname, subscribe: [{uname, :downstream}]
#
#      setports ["/dev/vtty0"]
#      assert :ok = UART.rescan uart
#
#      assert {:error, {:notfound, {:worker, :vtty0}}} = UART.worker :vtty0, uart
#
#      :ok =  :pg2.join uname, self
#
#      assert :ok = UART.open :vtty0, uart
#
#      {:ok, {:vtty0, tty}} = UART.worker :vtty0, uart
#
#      ev = ["#{uname}", "open"]
#      assert_receive {:'$tinyconnect', ^ev, %{id: :vtty0}}
#
#      # received from tty
#      send tty, {:serial, ref, recvd = <<35,1,0,0,0,1,0,0,0,0,0,0,0,2,0,0,2,18,0,0,0,0,0,1,126,115,255,0,0,0,0,2,0,1, 56>>}
#
#      ev = ["#{uname}", "data"]
#      assert_receive {:'$tinyconnect', ^ev, %{data: ^recvd, id: :vtty0}}
#
#      # we should now get an ACK
#      assert_receive {^ref, :send, <<6>>}
#    end
#  end
#
#  # When adding a network to the config this should automatically be
#  # included in the port definition such that we can control baudrate
#  # etc...
#  test "append config to portdef" do
#    alias :tinyconnect_handler_uart, as: UART
#
#
#    {parent, ref} = {self, make_ref}
#    with_mock :gen_serial, [
#        open: fn(path2, opts) ->
#                send parent, {ref, :open, path2, opts}
#                {:ok, ref}
#              end,
#        bsend: fn(ref, [buf], _timeout) -> send parent, {ref, :send, buf}; :ok end,
#        close: fn(_ref, _timeout) ->
#          send parent, {ref, :close}
#          :ok
#        end
#    ] do
#      :application.set_env(:tinyconnect, :config_path, Path.join(__DIR__, "append-portdef-test.cfg"))
#      {:ok, uart} = UART.start_link name = :"append-portdef-cfg-test"
#
#      setports ["/dev/vtty-custom-baud"]
#      assert :ok = UART.rescan uart
#
#      {_, _, _, opts} = assert_receive {^ref, :open, '/dev/vtty-custom-baud', _opts}
#      assert 76800 = opts[:baud]
#    end
#  end
#
##  test "identify" do
##    alias :tinyconnect_handler_uart, as: UART
##
##    {:ok, server} = UART.start_link name = :'uart-identify-test'
##    :ok =  :pg2.join name, self
##
##    setports ports = [{"/dev/vtty0", TinyconnectPhyMock}]
##    assert :ok = UART.rescan server
##
##    added      = "#{name}#added"
##    discovered = "#{name}#discovered"
##
##    assert_receive {:"$tinyconnect", ^added, :vtty0}
##
##    assert false
##  end
end

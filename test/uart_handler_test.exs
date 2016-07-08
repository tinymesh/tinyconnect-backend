defmodule UartHandlerTest do
  use ExUnit.Case, async: false

  import Mock

  setup do
    oldos = Application.get_env :tinyconnect, :os_type
    Application.put_env :tinyconnect, :os_type, {:test, []}

    on_exit fn() ->
      case oldos do
        nil -> Application.delete_env(:tinyconnect, :os_type)
        _   -> Application.put_env(:tinyconnect, :os_type, oldos)
      end
    end
  end

  def setports(newports) do
    Application.put_env(:tinyconnect, :os_type, {:test, newports})
  end

  test "auto-refresh uart ports" do
    alias :tinyconnect_handler_uart, as: UART

    {:ok, server} = UART.start_link name = :'auto-refresh-test'
    :ok =  :pg2.join name, self

    setports ports = ["/dev/vtty0"]

    assert :ok = UART.rescan server

    setports _newports = ["/dev/vtty1" | ports]
    assert :ok = UART.rescan server

    added   = ["#{name}", "added"]
    removed = ["#{name}", "removed"]

    assert_receive {:"$tinyconnect", ^added, :vtty0}
    assert_receive {:"$tinyconnect", ^added, :vtty1}

    setports _ports = ["/dev/vtty0"]
    assert :ok = UART.rescan server
    assert_receive {:"$tinyconnect", ^removed, :vtty1}

    assert :ok = :gen_server.call server, :stop
  end

  test "serial communications" do
    alias :tinyconnect_handler_uart, as: UART

    {parent, ref} = {self, make_ref}
    with_mock :gen_serial, [
        open: fn(_path2, _opts) -> {:ok, ref} end,
        bsend: fn(ref, [buf], _timeout) -> send parent, {ref, :send, buf}; :ok end,
        close: fn(_ref, _timeout) ->
          send parent, {ref, :close}
          :ok
        end
    ] do

      {:ok, server} = UART.start_link name = :'serial-communications-test'
      setports ["/dev/vtty0"]
      assert :ok = UART.rescan server

      assert {:error, {:notfound, {:worker, :vtty0}}} = UART.worker :vtty0, server

      :ok =  :pg2.join name, self

      assert :ok = UART.open :vtty0, server

      {:ok, {:vtty0, tty}} = UART.worker :vtty0, server

      ev = ["#{name}", "open"]
      assert_receive {:'$tinyconnect', ^ev, %{id: :vtty0}}

      send tty, {:serial, ref, recvd = <<35,1,0,0,0,1,0,0,0,0,0,0,0,2,0,0,2,18,0,0,0,0,0,1,126,115,255,0,0,0,0,2,0,1, 56>>}

      ev = ["#{name}", "data"]
      assert_receive {:'$tinyconnect', ^ev, %{data: ^recvd, id: :vtty0}}

      monitor = Process.monitor tty
      assert :ok = UART.close :vtty0, server

      ev = ["#{name}", "close"]
      assert_receive {:'$tinyconnect', ^ev, %{id: :vtty0}}
      assert_receive {:DOWN, ^monitor, :process, ^tty, :normal}
    end
  end

  test "send ack when stored in queue" do
    alias :tinyconnect_handler_uart, as: UART
    alias :tinyconnect_handler_queue, as: Queue

    {parent, ref} = {self, make_ref}
    with_mock :gen_serial, [
        open: fn(_path2, _opts) -> {:ok, ref} end,
        bsend: fn(ref, [buf], _timeout) -> send parent, {ref, :send, buf}; :ok end,
        close: fn(_ref, _timeout) ->
          send parent, {ref, :close}
          :ok
        end
    ] do

      uname = :'ack-uart-test'
      qname = :'ack-queue-test'

      {:ok, uart} = UART.start_link   uname, subscribe: [qname]
      {:ok, queue} = Queue.start_link qname, subscribe: [{uname, :downstream}]

      setports ["/dev/vtty0"]
      assert :ok = UART.rescan uart

      assert {:error, {:notfound, {:worker, :vtty0}}} = UART.worker :vtty0, uart

      :ok =  :pg2.join uname, self

      assert :ok = UART.open :vtty0, uart

      {:ok, {:vtty0, tty}} = UART.worker :vtty0, uart

      ev = ["#{uname}", "open"]
      assert_receive {:'$tinyconnect', ^ev, %{id: :vtty0}}

      # received from tty
      send tty, {:serial, ref, recvd = <<35,1,0,0,0,1,0,0,0,0,0,0,0,2,0,0,2,18,0,0,0,0,0,1,126,115,255,0,0,0,0,2,0,1, 56>>}

      ev = ["#{uname}", "data"]
      assert_receive {:'$tinyconnect', ^ev, %{data: ^recvd, id: :vtty0}}

      # we should now get an ACK
      assert_receive {^ref, :send, <<6>>}
    end
  end

#  test "identify" do
#    alias :tinyconnect_handler_uart, as: UART
#
#    {:ok, server} = UART.start_link name = :'uart-identify-test'
#    :ok =  :pg2.join name, self
#
#    setports ports = [{"/dev/vtty0", TinyconnectPhyMock}]
#    assert :ok = UART.rescan server
#
#    added      = "#{name}#added"
#    discovered = "#{name}#discovered"
#
#    assert_receive {:"$tinyconnect", ^added, :vtty0}
#
#    assert false
#  end
end

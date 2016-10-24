defmodule PluginTTY2Test do
  use ExUnit.Case, async: false

  import Mock

  test "incomplete arguments", %{test: name} do
    path = "/dev/vtty0"

    chan = "tty2-#{name}"
    {:ok, manager} = :channel_manager.start_link name

    plugins = [
      %{"name" => "vtty0",
        "plugin" => "tinyconnect_tty2"}
    ]

    :ok = :channel_manager.add %{"channel" => chan, "plugins" => plugins}, manager

    assert {:ok, [%{"state" => state, "plugins" => [plug]}]} = :channel_manager.channels manager
    assert :error = state
    assert %{"state" => %{"error" => %{"args" => args}}} = plug
    assert %{"options.baud" => _,
             "options.flow_control" => _,
             "path" => _} = args

    plugins2 = [Map.put(hd(plugins), "path", path)]
    {:ok, %{"plugins" => [plug]}} = :channel_manager.update chan, %{"plugins" => plugins2}, manager
    assert ["options.baud", "options.flow_control"] = Map.keys(plug["state"]["error"]["args"])

  end

  test "serial test", %{test: name} do
    path = "/dev/vtty1"
    ret = {ref, parent} = {make_ref, self}

    with_mock :gen_serial, [
        open: fn(path, opts) ->
          send parent, {ref, :open, path, opts, self}
          {:ok, ref}
        end,
        bsend: fn(ref, buf, _timeout) ->
          send parent, {ref, :send, buf}
          :ok
        end,
        close: fn(ref, _timeout) ->
          send parent, {ref, :close}
          :ok
        end] do

      # initialize channel with plugins
      {chan, chanhandler} = {"#{name}", :tinyconnect_channel2}
      {:ok, manager} = :channel_manager.start_link name
      :ok = :channel_manager.add %{"channel" => chan,
                                   "channel_handler" => chanhandler}, manager

      assert {:ok, {pid, ^chanhandler}} = :channel_manager.child chan, manager

      plugins = [
        %{"name" => "vtty1",
          "plugin" => "tinyconnect_tty2",
          "path" => path,
          "options" => %{"baud" => 9600, "flow_control" => "none"}},

        %{"name" => "output",
          "plugin" => &laststate(&1, &2, ret)},

        %{"name" => "input",
          "plugin" => &inputstage(&1, &2, ret)}
      ]
      assert {:ok, %{"plugins" => [_, _, _] = plugins}} = chanhandler.update %{"plugins" => plugins}, pid
      [%{"id" => ida} = a, %{"id" => idb} = b, %{"id" => idc} = c] = plugins
      a = Map.put a, "pipeline", ["serial", idb]
      c = Map.put c, "pipeline", ["serial", ida]

      assert {:ok, %{"plugins" => [%{"id" => ^ida},
                                   %{"id" => ^idb},
                                   %{"id" => ^idc}]}} = chanhandler.update %{"plugins" => [a, b, c]}, pid

      # assert we open gen_serial
      assert_receive {ref, :open, _path, _opts, fsm}

      # "received" from serial port
      buf = "hello"
      send fsm, {:serial, ref, buf}
      assert_receive {^ref, :state}

      # should be forwarded to `laststate`
      assert {:ok, %{"plugins" => [_, %{"state" => ^buf}, _]}} = chanhandler.get pid
      # recv side was OKEILY-DOKILY

      # Now test we can send data. plugin `c` is a loop that can be used
      # to emit data!
      assert_receive {^ref, :'input-start', input}
      send input, {ref, "world"}

      assert_receive {^ref, :send, "world"}
    end
  end

  def inputstage({:start, chan, %{"id" => plugid}}, _state, {ref, caller}) do
    {:ok, spawn(fn() ->
      send caller, {ref, :'input-start', self}
      inputloop(chan, plugid, {ref, caller})
    end)}
  end
  def inputloop(chan, plugid, {ref, caller}) do
    receive do
      {^ref, ev} ->
        :tinyconnect_channel2.emit({:global, chan}, plugid, :input, ev)
        inputloop chan, plugid, {ref, caller}
    end
  end

  def laststate({:start, _, _}, _state, _), do: {:ok, nil}
  def laststate(:serialize, state, _), do: {:ok, state}
  def laststate({:event, :input, data, _meta}, _state, {ref, caller}) do
    send caller, {ref, :state}
    {:state, data}
  end
end


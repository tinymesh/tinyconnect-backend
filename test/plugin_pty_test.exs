defmodule PluginPtyTest do
  use ExUnit.Case, async: false

  test "socat pipe", %{test: name} do
    {chan, chanhandler} = {"plugin-pty-#{name}", :tinyconnect_channel2}
    {:ok, manager} = :channel_manager.start_link name
    :ok = :channel_manager.add %{"channel" => chan,
                                 "channel_handler" => chanhandler}, manager

    assert {:ok, {pid, ^chanhandler}} = :channel_manager.child chan, manager

    link = "/tmp/pty-#{String.replace "#{name}", " ", "-"}"
    ret = {ref, parent} = {make_ref, self}
    plugins = [
      %{"name" => "in",
        "plugin" => &inputstage(&1, &2, ret),
        "pipeline" => ["serial", "pty"]},

      %{"name" => "pty",
        "plugin" => "tinyconnect_pty",
        "link" => link,
        "pipeline" => ["serial", "out"]},

      %{"name" => "out",
        "plugin" => &output(&1, &2, ret)}
    ]

    assert {:ok, %{"plugins" => [_inp, _pty, _outp]}} = chanhandler.update %{"plugins" => plugins}, pid

    assert_receive {^ref, :'input-start', inputpid}

    :timer.sleep 1
    assert {:ok, _} = File.stat(link)

    {:ok, port} = :gen_serial.open '#{link}', [active: true,
                                               packet: :none,
                                               baud: 19200,
                                               flow_control: :none]

    # make sure we can receive
    :ok = :gen_serial.bsend port, buf = "hello", 1000
    assert_receive {^ref, {:event, :input, ^buf, _meta}}, 1000

    # and that we can send
    send inputpid, {ref, resp = "world"}
    assert_receive {:serial, _port, ^resp}
  end

  def output({:start, _chan, _def}, _state, _ret), do: {:ok, nil}
  def output(:serialize, state, _), do: {:ok, state}
  def output({:event, :input, buf, _meta} = ev, _state, {ref, caller}) do
    send caller, {ref, ev}
    {:state, buf}
  end
  def output(_, :state, _), do: :ok

  def inputstage({:start, chan, %{"id" => plugid}}, _state, {ref, caller}) do
    {:ok, spawn(fn() ->
      send caller, {ref, :'input-start', self}
      inputloop(chan, plugid, {ref, caller})
    end)}
  end
  def inputstage(:serialize, _state, _), do: {:ok, nil}

  def inputloop(chan, plugid, {ref, caller}) do
    receive do
      {^ref, ev} ->
        :tinyconnect_channel2.emit({:global, chan}, plugid, :input, ev)
        inputloop chan, plugid, {ref, caller}
    end
  end
end

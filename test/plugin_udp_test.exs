defmodule PluginUDPTest do
  use ExUnit.Case, async: false

  test "udp socket", %{test: name} do
    {chan, chanhandler} = {"plugin-udp-#{name}", :tinyconnect_channel2}
    {:ok, manager} = :channel_manager.start_link name

    port = 6589
    {:ok, sock} = :gen_udp.open port, [:binary, {:active, false}, :inet6]

    ret = {ref, parent} = {make_ref, self}
    :ok = :channel_manager.add %{
      "channel" => chan,
      "channel_handler" => chanhandler,
      "plugins" => [
        %{"name" => "input",
          "plugin" => &inputstage(&1, &2, ret),
          "pipeline" => ["serial", "udp-client"]},

        %{"name" => "udp-client",
          "plugin" => "tinyconnect_udp",
          "remote" => "::1:#{port}",
          "pipeline" => ["serial", "state"]},

        %{"name" => "state",
          "plugin" => &output(&1, &2, ret)}
      ]}, manager

      assert_receive {^ref, :'input-start', inputpid}

      send inputpid, {ref, buf = "send something to udp"}
      assert {:ok, {addr, port, ^buf}} = :gen_udp.recv sock, 1, 100

      :ok = :gen_udp.send sock, addr, port, buf2 = "udp responds!"
      assert_receive {^ref, {:event, :input, ^buf2, _}}
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

defmodule PluginQueueTest do
  use ExUnit.Case, async: false

  test "forward and clear", %{test: name} do
    {chan, chanhandler} = {"plug-queue-forward", :tinyconnect_channel2}
    {:ok, manager} = :channel_manager.start_link name

    ret = {ref, _parent} = {make_ref, self}

    :ok = :channel_manager.add %{
      "channel" => chan,
      "channel_handler" => chanhandler,
      "plugins" => [
        %{"name" => "input",
          "plugin" => &inputstage(&1, &2, ret),
          "pipeline" => ["serial", "queue", ["parallel", "events-output",
                                                         ["serial", "queue-receiver",
                                                                    ["parallel", "events-output", "queue"]]]]},

        %{"name" => "queue",
          "plugin" => "tinyconnect_queue",
          "pipeline" => []},

        %{"name" => "queue-receiver",
          "plugin" => &output/2,
          "pipeline" => []},

        %{"name" => "events-output",
          "plugin" => &events/2}
      ]}, manager

    assert_receive {^ref, :'input-start', inputpid}, 1000


    assert {:ok, {pid, ^chanhandler}} = :channel_manager.child chan, manager
    {:ok, %{"plugins" => [_input, queue, _qrecv, _qout]}} = chanhandler.get pid

    {:ok, q} = :queue_manager.lookup "#{chan}/#{queue["name"]}"
    assert {:ok, []} = :notify_queue.as_list q

    send inputpid, {ref, buf = "queue input"}

    assert %{"queue" => q} = queue
    assert q === "#{chan}/queue"

    :timer.sleep 250
    {:ok, %{"plugins" => [_input, _queue, qrecv, qout]}} = chanhandler.get pid

    # ensure that queue outputted into qrecv
    assert [{_, ^buf}] = qrecv["state"]

    # ensure queue -> (events-output; queue-receiver -> (events-output; queue))
    # collects `queue` event and `forwarded` event
    assert [
      {:event, :forwarded, [{_, ^buf}], _meta},
      {:event, :queue, [{_, ^buf}], _meta2}
      ] = qout["state"]
  end

  def events({:start, _chan, _def}, _state), do: {:ok, []}
  def events(:serialize, state), do: {:ok, state}
  def events({:event, t, _ev, _meta} = event, state) when is_list(state) do
    {:state, [ event | state]}
  end

  def output({:start, _chan, _def}, _state), do: {:ok, []}
  def output(:serialize, state), do: {:ok, state}
  def output({:event, _t, items, _meta}, state) do
    {:emit, :forwarded, items, state ++ items}
  end

  def inputstage({:start, chan, %{"id" => plugid}}, _state, {ref, caller}) do
    pid = spawn fn() ->
      send caller, {ref, :'input-start', self}
      inputloop(chan, plugid, {ref, caller})
    end

    {:ok, pid}
  end
  def inputstage(_, _state, _), do: {:ok, nil}

  def inputloop(chan, plugid, {ref, caller}) do
    receive do
      {^ref, ev} ->
        :tinyconnect_channel2.emit({:global, chan}, plugid, :input, ev)
        inputloop chan, plugid, {ref, caller}
    end
  end
end


defmodule PluginsNewTest do
  use ExUnit.Case, async: false

  test "deframe protocol", %{test: name} do
    {:ok, manager} = :channel_manager.start_link name

    {chan, chanhandler} = {"test", :tinyconnect_channel2}
    plugins = [
      %{"name" => "forward", "plugin" => &__MODULE__.forward/2, "pipeline" => ["serial", "#deframe", "collect"]},
      %{"name" => "collect", "plugin" => &__MODULE__.collect/2},
      %{"name" => "#deframe", "plugin" => "tinyconnect_preload:deframe"}
    ]
    assert :ok = :channel_manager.add %{"channel" => chan,
                                        "channel_handler" => chanhandler,
                                        "plugins" => plugins}, manager

    assert {:ok, {pid, ^chanhandler}} = :channel_manager.child chan, manager
    assert {:ok, %{"plugins" => [forward | _plugins]}} = chanhandler.get pid


    <<a :: binary-size(5), b :: binary-size(2), c :: binary-size(4),
      d :: binary-size(3), e :: binary-size(6), f :: binary()>> = ev = <<
             35, 1, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 254, 126, 0, 0, 2, 14,
             0, 0, 0, 0, 0, 0, 121, 187, 0, 0, 0, 0, 0, 2, 0, 1, 34>>

    get = fn() ->
      {:ok, %{"plugins" => [_forward, collect | _]}} = chanhandler.get pid
      collect["state"]
    end

    assert :ok = chanhandler.emit pid, forward["id"], :input, a
    assert nil == get.()
    assert :ok = chanhandler.emit pid, forward["id"], :input, b
    assert nil == get.()
    assert :ok = chanhandler.emit pid, forward["id"], :input, c
    assert nil == get.()
    assert :ok = chanhandler.emit pid, forward["id"], :input, d
    assert nil == get.()
    assert :ok = chanhandler.emit pid, forward["id"], :input, e
    assert nil == get.()
    assert :ok = chanhandler.emit pid, forward["id"], :input, f
    assert {:data, ev} == get.()
  end

  def forward({:event, :input, x, _meta}, state), do: {:emit, :input, x, state}
  def forward(_, _state), do: :ok

  def collect({:event, t, x, _meta} = e, state), do: {:state, {t, x}}
  def collect(:serialize, state), do: {:ok, state}
  def collect({:start, _, _}, _state), do: {:ok, nil}
end

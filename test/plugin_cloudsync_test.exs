defmodule PluginCloudsyncTest do
  use ExUnit.Case, async: false

  import Mock

  test "data input", %{test: name} do
    recvref = make_ref
    sendref = make_ref
    parent = self

    with_mock :hackney, [
        request: fn
          (:post, _remote, _headers, body, []) ->
            send parent, {sendref, :body, body}
            {:ok, 200, [], sendref}
          (:get, _remote, _heders, _, [:async|_]) ->
            {:ok, recvref}
        end,
        body: fn(_ref) -> {:ok, "{\"saved\":[\"abcdef\"]}"} end
    ] do

      chan = "plugin-cloudsync-data"
      {:ok, manager} = :channel_manager.start_link name

      plugins = [
        {:tinyconnect_cloudsync, %{name: plugin = "cloudsync",
                                   subscribe: [{chan, ["mock"]}],
                                   auth: {:token, {"", ""}},
                                   remote: "http://the.void"}}
      ]

      :ok = :pg2.create [chan, plugin]
      :ok = :pg2.join [chan, plugin], self

      assert :ok = :channel_manager.add %{channel: chan, plugins: plugins}, manager
      assert_receive {:'$tinyconnect', [^chan, ^plugin], %{type: :open}}
      :tinyconnect_channel.emit [chan, "mock"], %{}, :data, %{data: ret = "hello"}

      assert_receive {^sendref, :body, "[{\"datetime\":\"undefined\",\"proto/tm\":\"aGVsbG8=\"}]"}
    end
  end


  test "notify queue input", %{test: name} do
    recvref = make_ref
    sendref = make_ref
    parent = self

    with_mock :hackney, [
        request: fn
          (:post, _remote, _headers, body, []) ->
            send parent, {sendref, :body, body}
            {:ok, 200, [], sendref}
          (:get, _remote, _heders, _, [:async|_]) ->
            {:ok, recvref}
        end,
        body: fn(_ref) -> {:ok, "{\"saved\":[\"abcdef\"]}"} end
    ] do
      chan = "plugin-cloudsync-queue-input"
      {:ok, manager} = :channel_manager.start_link name

      plugins = [
        {:tinyconnect_cloudsync, %{name: plugin = "cloudsync",
                                   subscribe: [{chan, ["queue"]}],
                                   queues: [:cloudqueue],
                                   auth: {:token, {"", ""}},
                                   remote: "http://the.void"}},
        {:tinyconnect_queue, %{name: qplugin = "queue",
                               queue: :cloudqueue,
                               subscribe: [{chan, ["3mock"]}]}}
      ]

      :ok = :pg2.create [chan, plugin]
      :ok = :pg2.join [chan, plugin], self
      :ok = :pg2.create [chan, qplugin]
      :ok = :pg2.join [chan, qplugin], self

      assert :ok = :channel_manager.add %{channel: chan, plugins: plugins}, manager
      assert_receive {:'$tinyconnect', [^chan, ^plugin], %{type: :open}}
      assert_receive {:'$tinyconnect', [^chan, ^qplugin], %{type: :open}}

      :tinyconnect_channel.emit [chan, "3mock"], %{}, :data, %{data: "data"}
      assert_receive {:'$tinyconnect', [^chan, ^qplugin], %{type: :update}}
      {_, _, buf} = assert_receive {^sendref, :body, _some}
      assert [%{"proto/tm" => "ZGF0YQ=="}] = :jsx.decode(buf, [:return_maps])
    end
  end

  test "remote input loop test", %{test: name} do
    recvref = make_ref
    sendref = make_ref
    parent = self

    with_mock :hackney, [
        request: fn
          (:post, _remote, _headers, body, []) ->
            send parent, {sendref, :body, body}
            {:ok, 200, [], sendref}
          (:get, _remote, _heders, _, [:async|_]) ->
            send parent, {recvref, :open}
            {:ok, recvref}
        end,
        body: fn(_ref) -> {:ok, "{\"saved\":[\"abcdef\"]}"} end
    ] do

      chan = "plugin-cloudsync-data"
      {:ok, manager} = :channel_manager.start_link name

      plugins = [
        {:tinyconnect_cloudsync, %{name: plugin = "cloudsync",
                                   subscribe: [],
                                   auth: {:token, {"", ""}},
                                   remote: "http://the.void"}}
      ]

      :ok = :pg2.create [chan, plugin]
      :ok = :pg2.join [chan, plugin], self

      assert :ok = :channel_manager.add %{channel: chan, plugins: plugins}, manager
      {_,_,%{pid: pid}} = assert_receive {:'$tinyconnect', [^chan, ^plugin], %{type: :open}}
      assert_receive {^recvref, :open}

      send pid, {:hackney_response, recvref, {:status, 200, []}}
      send pid, {:hackney_response, recvref, {:headers, []}}
      send pid, {:hackney_response, recvref, :jsx.encode(%{"proto/tm" => Base.encode64("world")})}

      assert_receive {:"$tinyconnect", [^chan, ^plugin], %{data: "world"}}
    end
  end
end

defmodule PluginHTTPSyncTest do
  use ExUnit.Case, async: false

  import Mock

  test "queue input and forward", %{test: name} do
    {sendref, recvref, parent} = {make_ref, make_ref, self}
    outputref = make_ref

    with_mock :hackney, hackneymock(sendref, recvref, parent) do
      {chan, chanhandler} = {"plug-httpsync-input", :tinyconnect_channel2}
      {:ok, manager} = :channel_manager.start_link name

      :ok = :channel_manager.add %{
        "channel" => chan,
        "channel_handler" => chanhandler,
        "plugins" => [
          %{"name" => "input",
            "plugin" => &inputstage(&1, &2),
            "pipeline" => ["serial", "httpsync", "collection"]},

          %{"name" => "httpsync",
            "plugin" => "tinyconnect_httpsync",
            "pipeline" => ["serial", "output"],
            "auth" => %{<<"fingerprint">> => "",
                        <<"key">> => ""},
            "remote" => "http://localhost:1234/"},

          %{"name" => "collection",
            "plugin" => &collectstage(&1, &2, {outputref, parent})},

          %{"name" => "output",
            "plugin" => &outputstage(&1, &2, {outputref, parent})}
        ]}, manager

      {:ok, {pid, ^chanhandler}} = :channel_manager.child chan, manager
      {:ok, %{"plugins" => [input, _sync, _collect, _output]}} = chanhandler.get pid


      items = Enum.sort [
        {:tinyconnect_httpsync.utc_datetime(:erlang.timestamp()), <<"abcdef">>},
        {:tinyconnect_httpsync.utc_datetime(:erlang.timestamp()), <<"ghijkl">>},
        {:tinyconnect_httpsync.utc_datetime(:erlang.timestamp()), <<"mnopqr">>},
        {:tinyconnect_httpsync.utc_datetime(:erlang.timestamp()), <<"stuvxy">>},
        {:tinyconnect_httpsync.utc_datetime(:erlang.timestamp()), <<"z01234">>}
      ]

      assert :ok = chanhandler.emit {:global, chan}, input["id"], :queue, items

      assert_receive {^sendref, :body, body}

      ## watch that collect is filled with forward events
      assert_receive {^outputref, :forwarded, items2}
      assert Enum.sort(items2) === Enum.sort(items)
    end
  end

  test "singular input and forward", %{test: name} do
    {sendref, recvref, parent} = {make_ref, make_ref, self}
    outputref = make_ref

    with_mock :hackney, hackneymock(sendref, recvref, parent) do
      {chan, chanhandler} = {"plug-httpsync-input", :tinyconnect_channel2}
      {:ok, manager} = :channel_manager.start_link name

      :ok = :channel_manager.add %{
        "channel" => chan,
        "channel_handler" => chanhandler,
        "plugins" => [
          %{"name" => "input",
            "plugin" => &inputstage(&1, &2),
            "pipeline" => ["serial", "httpsync", "collection"]},

          %{"name" => "httpsync",
            "plugin" => "tinyconnect_httpsync",
            "pipeline" => ["serial", "output"],
            "auth" => %{<<"fingerprint">> => "",
                        <<"key">> => ""},
            "remote" => "http://localhost:1234/"},

          %{"name" => "collection",
            "plugin" => &collectstage(&1, &2, {outputref, parent})},

          %{"name" => "output",
            "plugin" => &outputstage(&1, &2, {outputref, parent})}
        ]}, manager

      {:ok, {pid, ^chanhandler}} = :channel_manager.child chan, manager
      {:ok, %{"plugins" => [input, _sync, _collect, _output]}} = chanhandler.get pid

      assert :ok = chanhandler.emit {:global, chan}, input["id"], :input, buf = <<"aaaabbbbcccc">>

      {_, _, body} = assert_receive {^sendref, :body, _body}
      assert [%{}] = :jsx.decode(body, [:return_maps])

      # watch that collect is filled with forward events
      assert_receive {^outputref, :forwarded, [{_, ^buf}]}
    end
  end

  test "forward remote data", %{test: name} do
    {sendref, recvref, parent} = {make_ref, make_ref, self}
    outputref = make_ref

    with_mock :hackney, hackneymock(sendref, recvref, parent) do
      {chan, chanhandler} = {"plug-httpsync-input", :tinyconnect_channel2}
      {:ok, manager} = :channel_manager.start_link name

      :ok = :channel_manager.add %{
        "channel" => chan,
        "channel_handler" => chanhandler,
        "plugins" => [
          %{"name" => "httpsync",
            "plugin" => "tinyconnect_httpsync",
            "pipeline" => ["serial", "output"],
            "auth" => %{<<"fingerprint">> => "",
                        <<"key">> => ""},
            "remote" => "http://localhost:1234/"},

          %{"name" => "output",
            "plugin" => &outputstage(&1, &2, {outputref, parent})}
        ]}, manager

      assert_receive {^recvref, :open, pid}

      send pid, {:hackney_response, recvref, {:status, 200, []}}
      send pid, {:hackney_response, recvref, {:headers, []}}

      send pid, {:hackney_response, recvref, :jsx.encode(%{"proto/tm" => Base.encode64("hello")})}
      assert_receive {^outputref, :input, {:event, :input, "hello", _}}

      send pid, {:hackney_response, recvref, :jsx.encode(%{"proto/tm" => Base.encode64("world")})}
      assert_receive {^outputref, :input, {:event, :input, "world", _}}
    end
  end

  defp hackneymock(sendref, recvref, parent) do
    [
      request: fn
        (:post, _remote, _headers, body, []) ->
          Process.put :out, body
          send parent, {sendref, :body, body}
          {:ok, 200, [], sendref}

        (:get, _remote, _headers, _, [:async|_]) ->
          send parent, {recvref, :open, self}
          {:ok, recvref}
      end,
      body: fn(_ref) ->
        items = :jsx.decode Process.get(:out), [:return_maps]
        {:ok, :jsx.encode(%{saved: Enum.map(items, &(&1["datetime"]))})}
      end
    ]
  end

  defp collectstage({:start, _chan, _def}, _state, _ret), do: {:ok, []}
  defp collectstage(:serialize, state, _ret), do: {:ok, state}
  defp collectstage({:event, :forwarded, items, _meta}, state, {ref, parent}) do
    send parent, {ref, :forwarded, items}
    {:state, [items | state]}
  end

  defp outputstage({:start, _chan, _def}, _state, _ret), do: {:ok, []}
  defp outputstage(:serialize, state, _ret), do: {:ok, state}
  defp outputstage({:event, :input, item, _meta} = ev, state, {ref, parent}) do
    send parent, {ref, :input, ev}
    {:state, [item | state]}
  end

  defp inputstage(_, _state), do: :ok
end

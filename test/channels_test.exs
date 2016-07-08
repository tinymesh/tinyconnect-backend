defmodule ChannelsTestPlugin do
  use GenServer

  def name(pid), do: GenServer.call(pid, :name)
  def stop(pid), do: GenServer.call(pid, :stop)

  def start_link(channel, plugin) do
    GenServer.start_link(__MODULE__, [channel, plugin], [])
  end

  def init([chan, %{name: plug, parent: {ref, parent}}  = plugdef]) do
    case plugdef[:backoff] do
      {:undefined, _} ->
        :ok = :tinyconnect_channel.subscribe [chan, plug], plugdef

        send parent, {ref, :up, self}
        :tinyconnect_channel.emit [chan, plug], plugdef, :open, %{pid: self}

        {:ok, {chan, plugdef}}

      {_ref, _} ->
        send parent, {ref, :down, self}
        {:stop, :normal}
    end
  end

  def handle_info({:"$tinyconnect", [_chan, _name], _args} = ev, {_, plugdef} = state) do
    {ref, parent} = plugdef[:parent]
    send parent, {ref, :recv, ev}
    {:noreply, state}
  end
  def handle_info({:emit, data}, {chan, %{name: name} = plugdef} = state) do
    :tinyconnect_channel.emit [chan, name], plugdef, :data, %{data: data}
    {:noreply, state}
  end

  def handle_info(:stop, state), do: {:stop, :normal, state}
end

defmodule ChannelsTest do
  use ExUnit.Case, async: false

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


  test "channel API / empty", %{test: name} do
    {:ok, manager} = :channel_manager.start_link name

    chan = "test"
    assert {:error, {:noarg, :channel}} = :channel_manager.add %{}, manager
    assert :ok = :channel_manager.add %{channel: chan}, manager

    assert {:ok, [%{channel: chan,
                    plugins: [],
                    autoconnect: false,
                    source: :user}]} == :channel_manager.channels manager

    assert :ok = :channel_manager.remove chan, manager

    assert {:error, {:notfound, {:channel, ^chan}}} = :channel_manager.child chan, manager
  end

  test "channel plugin communications", %{test: name} do
    {:ok, manager} = :channel_manager.start_link name
    chan = "pipeit"

    left  = {ref_l = make_ref, self()}
    right = {ref_r = make_ref, self()}

    plugins = [
      {ChannelsTestPlugin, %{name: "left",  parent: left,  opts: [], subscribe: [{chan, ["right"]}]}},
      {ChannelsTestPlugin, %{name: "right", parent: right, opts: [], subscribe: [{chan, ["left"]}]}},
    ]

    assert :ok = :channel_manager.add %{channel: chan, plugins: plugins}, manager

    {_, _, pid_l} = assert_receive {^ref_l, :up, _}
    {_, _, pid_r} = assert_receive {^ref_r, :up, _}

    send pid_l, {:emit, "hello"}
    send pid_r, {:emit, "world"}

    assert_receive {^ref_r, :recv, {:"$tinyconnect", [^chan, "left"],  %{type: :data, data: "hello"}}}
    assert_receive {^ref_l, :recv, {:"$tinyconnect", [^chan, "right"], %{type: :data, data: "world"}}}
  end

  test "channel plugin backoff", %{test: name} do
    {:ok, manager} = :channel_manager.start_link name
    chan = "backoff"

    parent = {ref = make_ref, self()}

    plugins = [
      {ChannelsTestPlugin, %{name: "1-800-suicide",
                             parent: parent,
                             backoff: {:undefined, :backoff.init(50, 1000)}
                            }},
    ]

    assert :ok = :channel_manager.add %{channel: chan, plugins: plugins}, manager

    {_, _, pid} = assert_receive {^ref, :up, _}

    send pid, :stop
    assert :nothing = (receive do {^ref, :down, _} -> :started after 50 -> :nothing end)
    {_, _, pid} = assert_receive {^ref, :down, _}, 150

    send pid, :stop
    assert :nothing = (receive do {^ref, :down, _} -> :started after 200 -> :nothing end)
    {_, _, pid} = assert_receive {^ref, :down, _}, 400

    send pid, :stop
    assert :nothing = (receive do {^ref, :down, _} -> :started after 400 -> :nothing end)
    {_, _, pid} = assert_receive {^ref, :down, _}, 800
  end

  test "wait for startup", %{test: name} do
    {:ok, manager} = :channel_manager.start_link name
    chan = "backoff"

    parent_1 = {ref_1 = make_ref, self()}
    parent_2 = {ref_2 = make_ref, self()}
    parent_3 = {ref_3 = make_ref, self()}

    plugins = [
      {ChannelsTestPlugin, %{name: "third",  parent: parent_3, start_after: ["second"]}},
      {ChannelsTestPlugin, %{name: "second", parent: parent_2, start_after: ["first"]}},
      {ChannelsTestPlugin, %{name: "first",  parent: parent_1, start_after: []}},
    ]

    assert :ok = :channel_manager.add %{channel: chan, plugins: plugins}, manager

    assert ref_1 == (receive do {ref, :up, _} -> ref; x -> {:e, x} after 100 -> :timeout end)
    assert ref_2 == (receive do {ref, :up, _} -> ref; x -> {:e, x} after 100 -> :timeout end)
    assert ref_3 == (receive do {ref, :up, _} -> ref; x -> {:e, x} after 100 -> :timeout end)
  end
end

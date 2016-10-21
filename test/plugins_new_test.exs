defmodule PluginsNewTest do
  use ExUnit.Case, async: false

  test "Plugin API", %{test: name} do
    {:ok, manager} = :channel_manager.start_link name

    {chan, chanhandler} = {"test", :tinyconnect_channel2}
    assert :ok = :channel_manager.add %{"channel" => chan,
                                        "channel_handler" => chanhandler}, manager

    assert {:ok, {pid, ^chanhandler}} = :channel_manager.child chan, manager
    assert {:ok, %{"channel" => ^chan, "autoconnect" => false, "plugins" => []}} = chanhandler.get pid

    # Add the plugins
    plugins = [
      %{"plugin" => Test.Plugin.Stateless},
      %{"plugin" => Test.Plugin.GenServer},
      %{"plugin" => Test.Plugin.Agent},
    ]

    assert {:ok, %{"plugins" => [_a, b, _c]}} = chanhandler.update %{"plugins" => plugins}, pid
    b = Map.put b, :some, :value
    assert {:ok, %{"plugins" => [^b]}} = chanhandler.update %{"plugins" => [b]}, pid
  end

  # test that we can use functions within the beam runtime
  test "plugin forwarding", %{test: name} do
    {:ok, manager} = :channel_manager.start_link name

    {chan, chanhandler} = {"test", :tinyconnect_channel2}
    assert :ok = :channel_manager.add %{"channel" => chan,
                                        "channel_handler" => chanhandler}, manager

    assert {:ok, {pid, ^chanhandler}} = :channel_manager.child chan, manager
    plugins = [
      %{"name" => "forward",           "plugin" => &__MODULE__.forwardplugin/2},
      %{"name" => "nbytes#pre",        "plugin" => &__MODULE__.state_nbytes/2},
      %{"name" => "strip-downcase",    "plugin" => &__MODULE__.stateless_strip_downcase/2},
      %{"name" => "nbytes#strip-down", "plugin" => &__MODULE__.state_nbytes/2},
      %{"name" => "last#strip-down",   "plugin" => &__MODULE__.state_last/2},
      %{"name" => "strip-upcase",      "plugin" => &__MODULE__.stateless_strip_upcase/2},
      %{"name" => "nbytes#strip-up",   "plugin" => &__MODULE__.state_nbytes/2},
      %{"name" => "last#strip-up",     "plugin" => &__MODULE__.state_last/2},
    ]

    assert {:ok, %{"plugins" => [void|plugins]}} = chanhandler.update %{"plugins" => plugins}, pid
    [%{"id" => nbpre},
      %{"id" => dcase}, %{"id" => nbdcase}, %{"id" => lastdcase},
      %{"id" => ucase}, %{"id" => nbucase}, %{"id" => lastucase}] = plugins

    void = Map.put(void, "pipeline", ["parallel", nbpre,
                                                  ["serial", dcase, nbdcase, lastdcase],
                                                  ["serial", ucase, nbucase, lastucase]])

    assert {:ok, %{"plugins" => _updatedplugs}} = chanhandler.update %{"plugins" => plugins = [void|plugins]}, pid
    assert {:ok, chandef} = chanhandler.get pid
    assert length(plugins) == length(chandef["plugins"])

    # this emits an event on behalf of PluginID (void[:id])
    assert :ok = chanhandler.emit pid, void["id"], :input, <<"AaBbCcDdEeFfGgHhIiJjKkLlMmNnOoPp">>

    {:ok, %{"plugins" => plugins}} = chanhandler.get pid
    assert %{"state" => 32} = Enum.find plugins, &(&1["id"] == nbpre)
    assert %{"state" => "ABCDEFGHIJKLMNOP"} = Enum.find plugins, &(&1["id"] == lastdcase)
    assert %{"state" => 16} = Enum.find plugins, &(&1["id"] == nbdcase)
    assert %{"state" => "abcdefghijklmnop"} = Enum.find plugins, &(&1["id"] == lastucase)
    assert %{"state" => 16} = Enum.find plugins, &(&1["id"] == nbucase)
  end

  def forwardplugin({:event, :input, x, _meta}, state), do: {:emit, :input, x, state}
  def forwardplugin(_, _state), do: :ok

  # strip everything outside the range of A-Z
  def stateless_strip_downcase({:start, _, _}, _state), do: :ok
  def stateless_strip_downcase(:serialize, _state), do: :ok
  def stateless_strip_downcase({:event, :input, <<input:: binary>>, _meta}, state) do
    {:emit, :input, String.replace(input, ~r/[^A-Z]*/, ""), state}
  end

  # strip everything outside the range of a-z
  def stateless_strip_upcase({:start, _, _}, _state), do: :ok
  def stateless_strip_upcase(:serialize, _state), do: :ok
  def stateless_strip_upcase({:event, :input, <<input:: binary>>, _meta}, state) do
    {:emit, :input, String.replace(input, ~r/[^a-z]*/, ""), state}
  end

  # count number of bytes passed through
  def state_nbytes({:start, _, _}, :nostate), do: {:ok, 0}
  def state_nbytes(:serialize, state), do: {:ok, state}
  def state_nbytes({:event, :input, <<input :: binary>>, _meta}, n) do
    {:emit, :input, input, n + byte_size(input)}
  end

  def state_last({:start, _, _}, _state), do: {:ok, nil}
  def state_last(:serialize, state), do: {:ok, state}
  def state_last({:event, :input, data, _meta}, _state), do:
    {:state, data}
end

defmodule Test.Plugin.Stateless do
  @moduledoc """
  Stateless that runs in the context of the caller.
  """

  def handle(:name,  %{name: name}), do: {:ok, name}
  def handle(:state, %{}), do: {:ok, :stateless}

  # (un)serialize the plugin definition (args used to start plugin)
  def handle({:serialize, definition}, _), do: definition
  def handle({:unserialize, definition}, _), do: definition

  def handle({:start, _channel, _definition}, :nostate), do: :ok
  def handle(:stop, :nostate), do: :ok
end

defmodule Test.Plugin.Agent do
  @moduledoc """
  Stateless plugin that encapsulates some state
  """

  def handle(:name,  :nostate), do: {:ok, :nostate}
  def handle(:state, s) when is_list(s), do: {:ok, :stateless}

  # (un)serialize the plugin definition (args used to start plugin)
  def handle({:serialize, definition}, s) when is_list(s), do: definition
  def handle({:unserialize, definition}, s) when is_list(s), do: definition

  def handle({:start, _channel, _definition}, :nostate), do: {:ok, []}
  def handle(:stop, s) when is_list(s), do: :ok
end

defmodule Test.Plugin.GenServer do
  @moduledoc """
  A gen server implementation of a plugin, containing it's own state
  """
  use GenServer

  def handle(:name,  %{"name" => name}), do: {:ok, name}
  def handle(:state, %{}), do: {:ok, :stateless}

  # (un)serialize the plugin definition (args used to start plugin)
  def handle({:serialize, definition}, _), do: definition
  def handle({:unserialize, definition}, _), do: definition

  def handle({:start, channel, %{"id" => id} = definition}, :nostate) do
    GenServer.start_link __MODULE__, [channel, definition], name: {:global, id}
  end

  def handle(:stop, pid), do: GenServer.stop(pid)
end

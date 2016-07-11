defmodule PluginQueueTest do
  use ExUnit.Case, async: false

  test "takes input and forwards update event", %{test: name} do
      chan = "plugin-queue-basic"
      {:ok, manager} = :channel_manager.start_link name
      {:ok, _} = :queue_manager.ensure name, self

      plugins = [
        {:tinyconnect_queue, %{name: plugin = 'queue',
                               queue: queue = :q,
                               subscribe: [{chan, ["mock"]}]}}
      ]

      :ok = :pg2.create [chan, plugin]
      :ok = :pg2.join [chan, plugin], self

      assert :ok = :channel_manager.add %{channel: chan, plugins: plugins}, manager

      {_,_, %{pid: pid}} = assert_receive {:'$tinyconnect', [^chan, ^plugin], %{type: :open}}
      :tinyconnect_channel.emit [chan, "mock"], %{}, :data, %{data: "hello"}

      assert_receive {:'$tinyconnect', [^chan, ^plugin], %{type: :update, queue: ^queue}}
      assert {:ok, {_, "hello"}} = :notify_queue.peek queue
  end

  test "filter input (accept)", %{test: name} do
      chan = "plugin-queue-filter"
      {:ok, manager} = :channel_manager.start_link name
      {:ok, _} = :queue_manager.ensure name, self

      plugins = [
        {:tinyconnect_queue, %{name: plugin = 'queue',
                               queue: queue = :q2,
                               accept: fn(_, ev) -> false != ev[:accept] end,
                               subscribe: [{chan, ["2mock"]}]}}
      ]

      :ok = :pg2.create [chan, plugin]
      :ok = :pg2.join [chan, plugin], self

      assert :ok = :channel_manager.add %{channel: chan, plugins: plugins}, manager

      {_,_, %{pid: pid}} = assert_receive {:'$tinyconnect', [^chan, ^plugin], %{type: :open}}
      :tinyconnect_channel.emit [chan, "2mock"], %{}, :data, %{data: buf = "accepted"}

      assert_receive {:'$tinyconnect', [^chan, ^plugin], %{type: :update}}
      assert {:ok, {_, ^buf}} = :notify_queue.peek queue

      :tinyconnect_channel.emit [chan, "2mock"], %{}, :data, %{data: buf = "not-accepted", accept: false}
      refute_receive {:'$tinyconnect', [^chan, ^plugin], %{type: :update, queue: ^queue}}
  end
end

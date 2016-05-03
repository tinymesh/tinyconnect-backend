defmodule TinyconnectPhyTest do
  use ExUnit.Case, async: true

  alias :notify_queue, as: Queue

  test "peek" do
    q = :'peek-test'
    {:ok, _pid} = Queue.start_link q, self

    assert {:error, :empty} = Queue.peek q

    buf = "test-123"
    assert {:ok, {_, ^buf} = item} = Queue.add q, buf
    assert {:ok, ^item} = Queue.peek q
  end

  test "pop" do
    q = :'pop-test'
    {:ok, _pid} = Queue.start_link q, self

    buf = "test-456"
    {:ok, item} = Queue.add q, buf
    assert {:ok, {_, ^buf} = ^item} = Queue.peek q
    assert :ok = Queue.pop q, item

    assert {:error, :empty} = Queue.peek q

    assert :ok = Queue.pop q, item # pop on empty queue is noop
  end

  test "clear" do
    q = :'clear-test'
    {:ok, _pid} = Queue.start_link q, self

    buf = "test-clear"
    assert {:ok, _} = Queue.add q, buf
    assert :ok = Queue.clear q
    assert {:error, :empty} = Queue.peek q
  end

  test "notify" do
    q = :'clear-test'
    {:ok, _pid} = Queue.start_link q, self

    buf = "test-clear"
    {:ok, item} = Queue.add q, buf
    assert_received {:update, q}
    assert {:ok, {_, ^buf} = ^item} = Queue.peek q
  end
end

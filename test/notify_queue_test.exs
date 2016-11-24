defmodule NotifyQueueTest do
  use ExUnit.Case, async: true

  alias :notify_queue, as: Queue

  test "peek" do
    q = :'peek-test'
    {:ok, pid} = Queue.start_link q, self

    assert {:error, :empty} = Queue.peek pid

    buf = "test-123"
    assert {:ok, {_, ^buf} = item} = Queue.add pid, buf
    assert {:ok, ^item} = Queue.peek pid
  end

  test "pop" do
    q = :'pop-test'
    {:ok, pid} = Queue.start_link q, self

    buf = "test-456"
    {:ok, item} = Queue.add pid, buf
    assert {:ok, {_, ^buf} = ^item} = Queue.peek pid
    assert :ok = Queue.pop pid, item

    assert {:error, :empty} = Queue.peek pid

    assert :ok = Queue.pop pid, item # pop on empty queue is noop
  end

  test "clear" do
    q = :'clear-test'
    {:ok, pid} = Queue.start_link q, self

    buf = "test-clear"
    assert {:ok, _} = Queue.add pid, buf
    assert :ok = Queue.clear pid
    assert {:error, :empty} = Queue.peek pid
  end

  test "notify" do
    q = :'clear-test'
    {:ok, pid} = Queue.start_link q, self

    buf = "test-clear"
    {:ok, item} = Queue.add pid, buf
    assert_received {:'$notify_queue', {:update, ^q}}
    assert {:ok, {_, ^buf} = ^item} = Queue.peek pid
  end

  test "without" do
    q = :'without-test'
    {:ok, pid} = Queue.start_link q, self

    [a,b,c,d,e,f,g] = Enum.map ["a","b","c","d","e","f","g"], fn(x) ->
      {:ok, x2} = Queue.add pid, x
      x2
    end

    assert :ok === Queue.without pid, [b,c,e,f]
    assert {:ok, [a, d, g]} === Queue.as_list pid
  end
end

defmodule PluginsNewTest do
  use ExUnit.Case, async: false

  alias :tinyconnect_plugins, as: P

  defp input(e, meta \\ %{}), do: {:event, :input, e, meta}

  test "protostate" do
    # check that config mode is detected
    assert {:state, state} = P.protostate {:start, "", %{}}, :nostate
    assert {:state, {:config, _, _}} = P.protostate input(">"), state

    # protocol mode is assumed
    assert {:state, state} = P.protostate {:start, "", %{}}, :nostate
    assert {:state, {:config, _, _}} = P.protostate input(">"), state
    assert {:emit, :input, _, state} = P.protostate input(<<35,1,0,0,10>>), state
    assert {:emit, :input, _, state} = P.protostate input(<<16,0,0,0,0,0>>), state
    assert {:emit, :input, _, state} = P.protostate input(<<0>>), state
    assert {:emit, :input, _, state} = P.protostate input(<<0,2,0,0>>), state
    assert {:emit, :input, _, state} = P.protostate input(<<2,18,0,0,0,0>>), state
    assert {:emit, :input, _, state} = P.protostate input(<<0,29,159,114,255>>), state
    assert {:emit, :input, _, state = {:proto, _, _}} = P.protostate input(<<0,0,0,0,2,0,1,69>>), state

    # and back to config!
    assert {:state, {:config, _, <<>>}} = P.protostate input(">"), state

    # check that we only emit certain in certain modes
    opts = %{"emit" => ["config","unknown"]}
    assert {:state, state} = P.protostate {:start, "", opts}, :nostate
    assert {:emit, :input, "x", {:unknown, _, _state} = state} = P.protostate input("x"), state
    assert {:emit, :input, ">", {:config, _, _state} = state} = P.protostate input(">"), state

    frame = <<35, 1, 0, 0, 10, 16, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 2, 18, 0, 0, 0, 0, 0, 29, 159, 114, 255, 0, 0, 0, 0, 2, 0, 1, 69>>
    assert {:state, {:proto, _, _state}} = P.protostate input(frame), state
  end

  test "deframe event" do
    assert {:state, state = []} = P.deframe {:start, "", %{}}, :nostate

    # config mode drops previous state
    assert {:state, state = [_]} = P.deframe input(<<35, 1,2,3>>), state
    assert {:state, state = []} = P.deframe input(">"), state

    frame = <<35, 1, 0, 0, 10, 16, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 2, 18, 0, 0, 0, 0, 0, 29, 159, 114, 255, 0, 0, 0, 0, 2, 0, 1, 69>>
    assert {:state, state} = P.deframe input(<<35,1,0,0,10>>), state
    assert {:state, state} = P.deframe input(<<16,0,0,0,0,0>>), state
    assert {:state, state} = P.deframe input(<<0>>), state
    assert {:state, state} = P.deframe input(<<0,2,0,0>>), state
    assert {:state, state} = P.deframe input(<<2,18,0,0,0,0>>), state
    assert {:state, state} = P.deframe input(<<0,29,159,114,255>>), state
    suffix = <<35,1,0,0,10>>
    assert {:emit, :data, ^frame, [{_,^suffix}]} = P.deframe input(<<0,0,0,0,2,0,1,69>> <> suffix), state
  end
end


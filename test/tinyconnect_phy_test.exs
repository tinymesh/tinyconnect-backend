defmodule TinyconnectPhyTest do
  use ExUnit.Case, async: false

  import Mock

  test "serial communications" do
    {parent, ref} = {self, make_ref}
    halt = fn(_ref, _buf, _acc) -> {:halt, :normal} end
    cb = fn(_ref, buf, _acc) ->
      send parent, {ref, :recv, buf}
      {:next, <<>>, halt}
    end

    with_mock :gen_serial, [
        open: fn(_path2, _opts) -> {:ok, ref} end,
        bsend: fn(ref, [buf], _timeout) -> send parent, {ref, :send, buf}; :ok end,
        close: fn(_ref, _timeout) ->
          send parent, {ref, :close}
          :ok
        end
    ] do

      {:ok, server} = :tinyconnect_tty.start_link(<<"/dev/ttyUSB0">>, cb)

      :ok = :tinyconnect_tty.send buf = <<10, 0, 0, 0, 0, 0, 3, 16, 0, 0>>, server
      assert_receive {^ref, :send, ^buf}

      send server, {:serial, ref, recved = <<35,1,0,0,0,1,0,0,0,0,0,0,0,2,0,0,2,18,0,0,0,0,0,1,126,115,255,0,0,0,0,2,0,1, 56>>}
      assert_receive {^ref, :recv, ^recved}

      # cb puts tty handlers next callback to be `halt/2`, any data
      # terminates it
      send server, {:serial, ref, <<>>}
      assert_receive {^ref, :close}
    end
  end
end

#  @tag timeout: 3000
#  test "autoconfigure gateway" do
#    {:ok, server} = :tinyconnect_tty.start_link(<<"/dev/ttyUSB0">>, nid = <<"1">>)
#
#    :tinyconnect_tty.ensure server, nid, sid = 2, uid = 2
#    :ok = :pg2.join nid, self
#
#    :ok = :tinyconnect_tty.send nid, buf = <<10, 0, 0, 0, 0, 0, 3, 16, 0, 0>>
#
#    pid = self
#    assert_receive {:bus, {^pid, :upstream}, ^buf}
#    assert_receive {:bus, {^server, :downstream}, <<35, sid :: size(32), uid :: size(32), _ :: size(56), 2, 18, _ :: binary>>}
#
#    :ok = :tinyconnect_tty.stop server
#  end

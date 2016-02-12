defmodule TinyconnectPhyTest do
  use ExUnit.Case, async: false

  test "serial communications" do
    {:ok, server} = TinyconnectPhyMock.start_link(<<"/dev/ttyUSB0">>, nid = <<"1">>)

    :ok = :pg2.join nid, self

    :ok = :tinyconnect_tty.send nid, buf = <<10, 0, 0, 0, 0, 0, 3, 16, 0, 0>>
    send server, {:recv, <<35,1,0,0,0,1,0,0,0,0,0,0,0,2,0,0,2,18,0,0,0,0,0,1,126,115,255,0,0,0,0,2,0,1, 56>>}

    pid = self
    assert_receive {:bus, {^pid, ^nid, :upstream}, ^buf}, 1000
    assert_receive {:bus, {^server, ^nid, :downstream}, <<35, _ :: size(120), 2, 18, _ :: binary>>}

    :ok = TinyconnectPhyMock.stop server
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
end

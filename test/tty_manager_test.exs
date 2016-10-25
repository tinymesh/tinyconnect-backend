defmodule TTYManagerTest do
  use ExUnit.Case, async: false

  # Make sure that TTY manager rescans every nth second and picks up
  # whatever changes are there....
  #
  # The actual serial port list will be picked up in a OS specific manner
  # implemented in tty_manager:listports/1. For the sake of testing
  # the application parameter tinyconnect/test_ttys may be set to a list
  # of fake devices which will be expanded to ports.

  test "rescan ports", %{test: name} do
    :ok = :application.set_env(:tinyconnect, :test_ttys, {:test, []})
    {:ok, manager} = :tty_manager.start_link name

    assert {:ok, []} = :tty_manager.get manager

    port = "/dev/vtty0"
    :ok = :application.set_env(:tinyconnect, :test_ttys, {:test, [port]})
    assert {:ok, res = [%{id: id, path: ^port}]} = :tty_manager.refresh manager
    assert {:ok, ^res} = :tty_manager.get manager
    assert {:ok, hd(res)} == :tty_manager.get id, manager
  end

  test "notify changes", %{test: name} do
    :ok = :application.set_env(:tinyconnect, :test_ttys, {:test, []})
    {:ok, manager} = :tty_manager.start_link name

    assert {:ok, []} = :tty_manager.get manager
    :ok = :tty_manager.subscribe manager

    port = "/dev/vtty0"
    :ok = :application.set_env(:tinyconnect, :test_ttys, {:test, [port]})
    assert {:ok, res = [%{path: ^port}]} = :tty_manager.refresh manager

    assert_receive {:tty_manager, :ports, ^res}
    assert {:ok, ^res} = :tty_manager.get manager

    :ok = :tty_manager.unsubscribe manager

    :ok = :application.set_env(:tinyconnect, :test_ttys, {:test, []})
    assert {:ok, res = []} = :tty_manager.refresh manager
    refute_receive {:tty_manager, :ports, _}
  end
end

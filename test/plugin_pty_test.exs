defmodule PluginPtyTest do
  use ExUnit.Case, async: false

  test "socat pipe", %{test: name} do
    {:ok, manager} = :channel_manager.start_link name
    chan = "plugin-pty-#{name}"

    link = "/tmp/test-pty-#{String.replace "#{name}", " ", "-"}"
    plugins = [
      {:tinyconnect_pty, %{name: plugin = "pty",
                           subscribe: [{chan, ["mock"]}],
                           link: link}}
    ]

    :ok = :pg2.create [chan, plugin]
    :ok = :pg2.join [chan, plugin], self

    assert :ok = :channel_manager.add %{channel: chan, plugins: plugins}, manager
    assert_receive {:'$tinyconnect', [^chan, ^plugin], %{type: :open}}

    {:ok, port} = :gen_serial.open '#{link}', [active: true,
                                               packet: :none,
                                               baud: 19200,
                                               flow_control: :none]
    :ok = :gen_serial.bsend port, buf = "hello", 1000

    assert_receive {:"$tinyconnect", [^chan, ^plugin], %{data: ^buf}}
    :tinyconnect_channel.emit([chan, "mock"], %{}, :data, %{data: buf = "world"})
    assert_receive {:serial, ^port, ^buf}
  end
end

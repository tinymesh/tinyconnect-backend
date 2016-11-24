defmodule PluginUDPTest do
  use ExUnit.Case, async: false

  test "udp + httpsync" do
    port = 9134
    {:ok, sock} = :gen_udp.open port, [:binary, {:active, false}, :inet6]

    {:ok, channels} = :channel_manager.channels
    channel = Enum.find channels, &(&1["channel"] === "udp to httpsync")
    plugin = Enum.find channel["plugins"], &(&1["plugin"] === "tinyconnect_httpsync")
    %{"auth" => %{"fingerprint" => fprint, "key" => key}} = plugin

    appremote = String.replace plugin["remote"], "@tinymesh", "@application"

    cmd = <<10, 0, 0, 0, 1, 0, 3, 17, 0, 0>>
    body = :jsx.encode [%{<<"proto/tm">> => :base64.encode(cmd)}]

    sig = :base64.encode(:crypto.hmac(:sha256, key, "POST\n#{appremote}\n#{body}"))
    headers = [{"Authorization", "#{fprint} #{sig}"}]

    assert {:ok, 200, _headers, ref} = :hackney.request(:post, appremote, headers, body, [])
    {:ok, _} = :hackney.body ref

    assert {:ok, {addr, port, ^cmd}} = :gen_udp.recv sock, 1, 1000

    resp = <<35, 1, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 254, 126, 0, 0, 2, 14,
             0, 0, 0, 0, 0, 0, 121, 187, 0, 0, 0, 0, 0, 2, 0, 1, 34>>

    :ok = :gen_udp.send sock, addr, port, resp

    # check that response can be found on @application side
    sig = :base64.encode(:crypto.hmac(:sha256, key, "GET\n#{appremote}\n"))
    headers = [{"Authorization", "#{fprint} #{sig}"}]
    {:ok, 200, _headers, ref} = :hackney.request :get, appremote, headers, "", []
    {:ok, chunk} = :hackney.stream_body(ref)

    %{"proto/tm" => recv} = :jsx.decode chunk, [:return_maps]

    assert resp === Base.decode64! recv
    assert :ok = :hackney.close(ref)
  end

  """
  Virtual serial port scenario

  - some local application speaks to pty
  - pty is linked with some downstream plugin (tty, udp, ...)
  - httpsync picks up data from both pty and downstream and mirrors it to remote service
  - httpsync can also speak to downstream
  """
  test "(pty <> udp <) > httpsync" do
    {:ok, channels} = :channel_manager.channels
    channel = Enum.find channels, &(&1["channel"] === "httpsync + pty + udp")

    sync = Enum.find channel["plugins"], &(&1["plugin"] === "tinyconnect_httpsync")
    %{"auth" => %{"fingerprint" => fprint, "key" => key}} = sync

    udp = Enum.find channel["plugins"], &(&1["plugin"] === "tinyconnect_udp")
    pty = Enum.find channel["plugins"], &(&1["plugin"] === "tinyconnect_pty")

    # open the serial port
    {:ok, tty} = :gen_serial.open '#{pty["link"]}', [active: true,
                                                     packet: :none,
                                                     baud: 19200,
                                                     flow_control: :none]

    # open downstream connection
    port = 9135
    {:ok, sock} = :gen_udp.open port, [:binary, {:active, false}, :inet6]

    # open @application remote channel that reads the received data
    appremote = String.replace sync["remote"], "@tinymesh", "@application"
    sig = :base64.encode(:crypto.hmac(:sha256, key, "GET\n#{appremote}\n"))
    headers = [{"Authorization", "#{fprint} #{sig}"}]

    {:ok, 200, _headers, req} = :hackney.request :get, appremote, headers, "", []

    # whatever we send from application should be received both upstream and downstream
    cmd = <<10, 0, 0, 0, 1, 0, 3, 17, 0, 0>>
    :ok = :gen_serial.bsend tty, cmd, 1000
    assert {:ok, {addr, port, ^cmd}} = :gen_udp.recv sock, 1, 1000

    {:ok, chunk} = :hackney.stream_body(req)
    %{"proto/tm" => recv} = :jsx.decode chunk, [:return_maps]
    assert cmd === Base.decode64! recv

    # lets give a response and see that it appears both upstream and appside
    resp = <<35, 1, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 254, 126, 0, 0, 2, 14,
             0, 0, 0, 0, 0, 0, 121, 187, 0, 0, 0, 0, 0, 2, 0, 1, 34>>

    :ok = :gen_udp.send sock, addr, port, resp

    {:ok, chunk} = :hackney.stream_body(req)
    %{"proto/tm" => recv} = :jsx.decode chunk, [:return_maps]
    assert resp === Base.decode64! recv

    assert_receive {:serial, ^tty, ^resp}
  end

  test "pickup config mode" do
    port = 9136
  end
end

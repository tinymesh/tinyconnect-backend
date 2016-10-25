defmodule WebSocketAPITest do
  use ExUnit.Case, async: false

  alias Socket.Web, as: WS

  def client do
    port = Application.get_env :tinyconnect, :port, 8181
    WS.connect!({"localhost", port}, path: "/ws")
  end

  def ref, do: (:random.uniform 72057594037927935) |> Integer.to_string(36)

  def write(socket, cmd, json \\ %{}) do
    myref = ref

    {WS.send(socket, {:text, "#{myref} #{Enum.join(cmd, " ")} #{:jsx.encode(json)}"}), myref}
  end

  def recv(socket, ref) do
    case WS.recv! socket do
      {:ping, _} -> WS.send socket, {:pong, ""}
      {:text, buf} ->
        case String.split buf, " ", parts: 2 do
          [^ref, rest] -> {:ok, :jsx.decode(rest, [:return_maps])}
        end
    end
  end

  setup do
    {:ok, channels} = :channel_manager.channels
    Enum.each channels, fn(%{"channel" => chan}) ->
      :ok = :channel_manager.disconnect chan
      :ok = :channel_manager.remove chan
    end
  end

  test "create channel -> update -> delete" do
    sock = client

    {:ok, sendref} = write sock, ["channels", "list"]
    assert {:ok, %{"resp" => %{"channels" => []}}} == recv sock, sendref

    {:ok, sendref} = write sock, ["channels", "new"]
    :timer.sleep 50
    assert {:ok, %{"resp" => %{"channels" => [%{"channel" => chank} = chan]}}} = recv sock, sendref

    autoconnect = not chan["autoconnect"]
    {:ok, sendref} = write sock, ["channels", "update", chank], %{"autoconnect" => autoconnect}
    assert {:ok, %{"resp" => %{"channels" => [%{"channel" => ^chank,
                                                "autoconnect" => ^autoconnect}]}}} = recv sock, sendref

    # Completely invalid keys are handeled
    {:ok, sendref} = write sock, ["channels", "update", chank], %{"random-arg" => -1}
    {:ok, %{"error" => %{"invalidkey" => "random-arg"}}} = recv sock, sendref

    {:ok, sendref} = write sock, ["channels", "remove", chank]
    assert {:ok, %{"resp" => %{"channels" => []}}} == recv sock, sendref
  end

  test "no plugin arg" do
    # see what happends when `plugin` is not defined
  end

  test "create channel -> update plugins" do
    sock = client

    {:ok, sendref} = write sock, ["channels", "list"]
    assert {:ok, %{"resp" => %{"channels" => []}}} == recv sock, sendref

    {:ok, sendref} = write sock, ["channels", "new"]
    assert {:ok, %{"resp" => %{"channels" => [%{"channel" => chank, "plugins" => []}]}}} = recv sock, sendref

    plugin = %{"plugin" => Test.Plugin.WSChannelsPlugin}
    {:ok, sendref} = write sock, ["channels", "update", chank], %{"plugins" => [plugin]}
    assert {:ok, %{"resp" => %{"channels" => [%{"channel" => ^chank, "plugins" => [_plugin]}]}}} = recv sock, sendref
  end

  test "create channel -> started?" do
    sock = client

    {:ok, sendref} = write sock, ["channels", "list"]
    assert {:ok, %{"resp" => %{"channels" => []}}} == recv sock, sendref

    plugin = %{"plugin" => Test.Plugin.WSChannelsPlugin,
               "name"   => "plugin test"}
    {:ok, sendref} = write sock, ["channels", "new"], %{"plugins" => [plugin]}
    assert {:ok, %{"resp" => %{"channels" => [%{"channel" => _chank} = chan]}}} = recv sock, sendref
    assert "started" = chan["state"]
    assert false == chan["autoconnect"]
  end

  defmacrop timeout(call, time \\ 1000) do
    quote do
      {ref, parent} = {make_ref, self}
      spawn_link fn() -> send parent, {ref, unquote(call)} end
      receive do
        {^ref, res} -> {:ok, res}
      after unquote(time) -> {:error, :timeout} end
    end
  end

  test "tty_manager subscription and publish" do
    sock = client

    port = "/dev/vtty0"
    :ok = :application.set_env(:tinyconnect, :test_ttys, {:test, [port]})
    assert {:ok, res = [%{"path" => ^port}]} = :tty_manager.refresh :tty_manager

    assert {:ok, {:text, "null " <> json}} = timeout WS.recv!(sock)
    assert %{"resp" => %{"serialports" => ^res}} = :jsx.decode(json, [:return_maps])
  end
end


defmodule Test.Plugin.WSChannelsPlugin do
  def handle({:start, _chan, _def}, _state), do: :ok
end

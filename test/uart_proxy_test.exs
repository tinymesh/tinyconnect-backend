defmodule UartProxyHandlerTest do
  use ExUnit.Case, async: false

  setup do
    oldos = Application.get_env :tinyconnect, :os_type
    Application.put_env :tinyconnect, :os_type, {:test, []}

    on_exit fn() ->
      case oldos do
        nil -> Application.delete_env(:tinyconnect, :os_type)
        _   -> Application.put_env(:tinyconnect, :os_type, oldos)
      end
    end
  end

  def setports(newports) do
    Application.put_env(:tinyconnect, :os_type, {:test, newports})
  end


  test "socat pipe" do
    alias :tinyconnect_handler_uart, as: UART
    alias :tinyconnect_handler_uartproxy, as: Proxy

    true = Process.register self(), upstream = :'socat-up'

    {:ok, proxy} = Proxy.start_link downstream = :'socat-down', [subscribe: [upstream],
                                                                 export_dir: "/tmp/socats"]

    :ok = :pg2.create downstream
    :ok = :pg2.join downstream, self

    arg = %{mod: __MODULE__, name: upstream, id: :vtty0, type: UART.name}
    assert :ok = :tinyconnect.emit({:open,  arg}, upstream)

    {_, _, %{paths: [path|_]}} = assert_receive {:"$tinyconnect", [_, "open"], %{type: :uartproxy}}

    {:ok, tty} = :tinyconnect_tty.start_link path, fn
      (port, <<0>>, _)     -> :gen_serial.bsend(port, <<1>>);      {:continue, <<>>}
      (port, <<1>>, _)     -> :gen_serial.bsend(port, "2");        {:continue, <<>>}
      (port, <<"2">>, _)   -> :gen_serial.bsend(port, <<0,255>>);  {:continue, <<>>}
      (port, <<0,255>>, _) -> :gen_serial.bsend(port, <<"halt">>); {:halt, :normal}
    end

    :ok = :tinyconnect_tty.send "hello", tty
    assert_receive {:"$tinyconnect", [_, "data"], %{data: "hello", type: :uartproxy}}

    assert :ok = :tinyconnect.emit({:data,  %{id: :vtty0, data: <<0>>}}, upstream)
    {_, _, %{data: next}} = assert_receive {:"$tinyconnect", [_, "data"], %{type: :uartproxy}}

    assert :ok = :tinyconnect.emit({:data,  %{id: :vtty0, data: next}}, upstream)
    {_, _, %{data: next}} = assert_receive {:"$tinyconnect", [_, "data"], %{type: :uartproxy}}

    assert :ok = :tinyconnect.emit({:data,  %{id: :vtty0, data: next}}, upstream)
    {_, _, %{data: next}} = assert_receive {:"$tinyconnect", [_, "data"], %{type: :uartproxy}}

    assert :ok = :tinyconnect.emit({:data,  %{id: :vtty0, data: next}}, upstream)
    assert_receive {:"$tinyconnect", [_, "data"], %{type: :uartproxy, data: "halt"}}

    :ok = Proxy.stop proxy
  end
end

defmodule HandlersTest do
  use ExUnit.Case, async: true

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

  @nidev <<35, 1, 0, 0, 10, 16, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 2, 18, 0, 0, 0, 0, 0, 29, 159, 114, 255, 0, 0, 0, 0, 2, 0, 1, 69>>

  # this requires an actual live serial port at /dev/ttyUSB0
  test "uart <> uartproxy communications" do
    alias :tinyconnect_handler_uart, as: UART

    spawnport path = "/tmp/vtty0"
    setports [path]
    id = :vtty0

    UART.rescan

    :pg2.join :uart, self
    :pg2.join :uartproxy, self

    :ok = UART.open id

    assert_receive {:"$tinyconnect", ["uart", "open"], %{id: ^id, path: ^path, type: :uart}}
    {_, _, %{paths: [link]}} = assert_receive {:"$tinyconnect", ["uartproxy", "open"], %{id: ^id, type: :uartproxy}}

    {:ok, tty} = :tinyconnect_tty.start_link link, fn(_port, _buf, _acc) ->
      {:continue, <<>>}
    end

    :ok = :tinyconnect_tty.send <<10,0,0,0,0, 0,3,16,0,0>>, tty

    # we send above, spawnport does the response and we should be able
    # take_it_all flushes and concats all uart/data events
    assert @nidev == Enum.join(Enum.reverse(take_it_all))
  end

  def spawnport(path) do
    [_|_] = exec = :os.find_executable('socat')

    spawn_link fn() ->
      port = :erlang.open_port({:spawn_executable, exec}, [
        {:env, []},
        :binary,
        :exit_status,
        {:args, [<<"PTY,link=", path :: binary(), ",raw">>, <<"-">>]},
        :stderr_to_stdout
      ])

      loop port
    end
  end

  def loop(port) do
    receive do
      {^port, {:data, <<10,0,0,0,0, 0,3,16,0,0>>}} ->
        <<a :: binary-size(5), b :: binary-size(2), c :: binary-size(5), d :: binary>> = @nidev
        true = :erlang.port_command port, a
        :timer.sleep 1
        true = :erlang.port_command port, b
        :timer.sleep 1
        true = :erlang.port_command port, c
        :timer.sleep 1
        true = :erlang.port_command port, d

        loop port

      x ->
        :noooooo = x
        loop port
    end
  end


  def take_it_all, do: take_it_all([])
  def take_it_all(acc) do
    receive do
      {:"$tinyconnect", ["uart", "data"], %{data: buf}} ->
        take_it_all([buf | acc])
    after 5 ->
      acc
    end
  end
end

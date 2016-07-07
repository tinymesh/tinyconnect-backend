ExUnit.start

defmodule TinyconnectPhyMock do
  use GenServer

  def start_link(_port, nid) do
    GenServer.start_link __MODULE__, [nid], [name: {:local, :"#{nid}"}]
  end

  def init([group]) do
   case :pg2.join group, self do
      {:error, {:no_such_group, ^group}} ->
         :ok = :pg2.create group
         :ok = :pg2.join group, self

      :ok ->
         :ok
   end

    {:ok, %{ nid: group, rest: "" }}
  end

  def stop(server) do
    GenServer.cast server, :stop
  end

  def handle_call({:send, _buf}, _from, state) do
    {:reply, :ok, state}
  end

  def handle_cast(:stop, state) do
    {:stop, :normal, state}
  end

  def handle_info({:recv, buf}, %{nid: nid} = state) do
    case :pg2.get_members(nid) do
      {:error, {:no_such_group, _}} ->
        :ok

      items ->
        Enum.each items, fn(pid) -> send pid, {:bus, {self, nid, :downstream}, buf} end
    end

    {:noreply, state}
  end

  def handle_info({:bus, {_pid, _nid, :downstream}, _buf}, state) do
    {:noreply, state}
  end

  def handle_info({:bus, {_pid, _nid, :upstream}, _buf}, state) do
    {:noreply, state}
  end
end


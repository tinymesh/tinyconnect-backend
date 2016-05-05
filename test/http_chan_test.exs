defmodule HttpChanTest do
  use ExUnit.Case, async: false

  alias :tinyconnect_chan_http, as: HTTPChan

  def post(url, data, {:token, id, key}) do
    {:ok, remote} =  :application.get_env :tinyconnect, :remote

    url = "#{remote}#{url}"
    body = Poison.encode! data

    signreq = "POST\n#{url}\n#{body}"

    signature = :base64.encode(:crypto.hmac(:sha256, key, signreq))
    request :post, url, [{"Authorization", "#{id} #{signature}"}], body
  end
  def post(url, data, {:user, user, password}) do
    {:ok, remote} =  :application.get_env :tinyconnect, :remote

    url = "#{remote}#{url}"
    body = Poison.encode! data

    auth = "Basic #{:base64.encode("#{user}:#{password}")}"
    request :post, url, [{"Authorization", auth}], body
  end

  def get(url, {:token, id, key}) do
    {:ok, remote} =  :application.get_env :tinyconnect, :remote

    url = "#{remote}#{url}"

    signreq = "GET\n#{url}\n"

    signature = :base64.encode(:crypto.hmac(:sha256, key, signreq))
    request :get, url, [{"Authorization", "#{id} #{signature}"}]
  end

  def request(method, url, headers, body \\ "")

  def request(method, url, headers, body) do
    {:ok, status, _headers, ref} = apply :hackney, method, [url, headers, body, []]
    {:ok, body} = :hackney.body ref

    {:ok, status, Poison.decode!(body)}
  end

  setup_all do
    {:ok, remote} =  :application.get_env :tinyconnect, :remote
    case request :post, "#{remote}/user/register", [], "{\"email\":\"dev@nyx.co\",\"password\":\"1qaz!QAZ\"}" do
      {:ok, 403, _body} ->
        {:ok, 201, token} = post "/auth/token", %{"name" => "test"}, {:user, "dev@nyx.co", "1qaz!QAZ"}
        {:ok, %{"token" => {:token, token["fingerprint"], token["key"]}}}

      {:ok, 201, _body} ->
        {:ok, 201, token} = post "/auth/token", %{"name" => "test"}, {:user, "dev@nyx.co", "1qaz!QAZ"}
        {:ok, %{"token" => {:token, token["fingerprint"], token["key"]}}}
    end
  end


  def createsetup({:token, fp, k} = token) do
    {:ok, status, net} = post "/network", %{}, token
    assert 201 === status

    {:ok, status, dev} = post "/device/#{net["key"]}", %{"type" => "gateway", "address" => 1}, token
    assert 201 === status

    cfg = Application.get_env :tinyconnect, :networks, %{}
    Application.put_env :tinyconnect, :networks, Map.put(cfg, net["key"], %{:token => {fp, k}})
    {:ok, net["key"], dev["key"]}
  end


  test "data persists accross disconnects`", %{"token" => token} do
    # this is race cond waiting to happen, httpchan may actually take
    # the item from queue before we manage to peek into it.
    {:ok, nid, _key} = createsetup token
    {:ok, pid} = HTTPChan.start nid, nil


    {:ok, queue} = HTTPChan.queue pid

    # check that after killing it we can still push to the queue
    ref = Process.monitor pid
    Process.exit pid, :kill
    assert_receive {:DOWN, ^ref, _, _, _}
    #:ok = :gen_server.call pid, :stop

    {:ok, item} = :notify_queue.add queue, "test"

    {:ok, pid} = HTTPChan.start nid, nil
    ref = Process.monitor pid

    assert {:ok, ^item} = HTTPChan.peek pid
    :ok = :gen_server.call pid, :stop

    assert_received {:DOWN, ^ref, _, _, :normal}
  end

  test "retreive incoming data", %{"token" => token} do
    {:ok, nid, dev} = createsetup token
    {:ok, pid} = HTTPChan.start nid, nil


    downstream = :"downstream:queue:#{nid}"
    {:ok, _} = :queue_manager.ensure downstream
    :notify_queue.forward downstream, self


    body = %{"proto/tm" => %{"type" => "command", "command" => "get_status", "cmd_number" => 1}}
    {:ok, 201, msg} = post "/message/#{nid}/#{dev}", body, token

    assert_receive {:update, ^downstream}, 5000, "lol"

    assert {:ok, {_, <<10,1,0,0,0,1,3,17,0,0>>}} = :notify_queue.peek downstream
  end
end

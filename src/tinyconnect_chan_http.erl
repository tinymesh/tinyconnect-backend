-module(tinyconnect_chan_http).
-behaviour(gen_server).

-export([
     start_link/2
   , start/2

   , queue/1
   , peek/1

   , push/2
   , push/3

   , init/1
   , handle_call/3
   , handle_cast/2
   , handle_info/2
   , terminate/2
   , code_change/3
]).

-define(USERAGENT, "tinyconnect").
-define(BACKOFF_MAX, 600).

queue(Server) -> gen_server:call(Server, queue).
peek(Server)  -> gen_server:call(Server, peek).






auth_header(_Method, _URL, _Body, {user, {ID, Key}}) ->
   Encoded = base64:encode(<<ID:(byte_size(ID))/binary, ":", Key/binary>>),
    <<"Basic ", Encoded>>;

auth_header(Method, URL, Body, {token, {ID, Key}}) ->
   Payload = iolist_to_binary([Method, "\n", URL, "\n", Body]),
   Signature = crypto:hmac(sha256, Key, Payload),
    <<ID:(byte_size(ID))/binary, Signature/binary>>.

% send actual data to server
push(NID, Data) ->
   push(NID, Data, fibnit(?BACKOFF_MAX)).

push(NID, Data, [Backoff | Rest]) ->
   {_T, {_ID, _Key}} = Auth = get_auth(NID),

   {ok, Remote} =  application:get_env(tinyconnect, remote),
   QueryParams = "?data.encoding=base64",
   URL = iolist_to_binary([Remote, "/message/", NID, QueryParams]),

   Body = case Data of
      <<Data/binary>> -> Data;
      Data when is_list(Data); is_map(Data) -> 'Elixir.Poison':'encode!'(Data)
   end,

   Authorization = auth_header("POST", URL, Body, Auth),

   case hackney:post(URL, [{"Authorization", Authorization}, {"User-Agent", ?USERAGENT}], Body) of
      {ok, 201, _Headers, _Ref} ->
         {ok, saved};

      % Unacceptable data, discard from queue
      {ok, Status, _Headers, _Ref} when Status >= 400 andalso Status < 500 ->
         {ok, discard};

      % Server did not respond correctly.... Retry in `Backoff` % seconds
      {ok, _Status, _Headers, _Ref} ->
         io:format("chan:http[upstream:chan:~s]: push failed, retrying in ~s ~n.", [NID, Backoff]),
         {wait, timer:send_after(Backoff * 1000, push_retry)}
   end.

get_auth(NID) ->
   Env =  application:get_env(tinyconnect, networks, #{}),
   case maps:get(NID, Env, undefined) of
      undefined -> undefined;
      #{token := {ID, Key}} -> {token, {ID, Key}};
      #{user := {ID, Key}} -> {user, {ID, Key}}
   end.







start_link(NID, PortID) ->
   RegName = binary_to_atom(<<"upstream:chan:", NID/binary>>, utf8),
   gen_server:start_link({local, RegName}, ?MODULE, [NID, PortID], []).

start(NID, PortID) ->
   RegName = binary_to_atom(<<"upstream:chan:", NID/binary>>, utf8),
   gen_server:start({local, RegName}, ?MODULE, [NID, PortID], []).

init([NID, _PortID]) ->
   RemoteQueue = binary_to_atom(<<"upstream:queue:", NID/binary>>, utf8),
   ForwardQueue = binary_to_atom(<<"downstream:queue:", NID/binary>>, utf8),
   io:format("chan:http[upstream:chan:~s]: connected~n.", [NID]),

   {ok, _RemoteQueuePud}  = queue_manager:ensure(RemoteQueue),
   {ok, _ForwardQueuePid} = queue_manager:ensure(ForwardQueue),
   ok = notify_queue:forward(RemoteQueue, self()),

   query(NID, #{
      nid => NID,
      queue => RemoteQueue,
      forward => ForwardQueue,
      clientref => undefined,
      timer => false
   }).

query(NID, State) ->
   case get_auth(NID) of
      undefined -> {error, {nocfg, {network, NID}}};

      Auth ->
         {ok, ClientRef} = open_stream(NID, Auth),
         {ok, State#{clientref := ClientRef}}
   end.

query_url(NID) ->
   {ok, Remote} =  application:get_env(tinyconnect, remote),
   QueryParams = #{ "date.from" => "NOW"
                  , "stream" => "true"
                  , "continuous" => "true"
                  , "data.encoding" => "base64"
                  %, "query" => "proto/tm.type%20==%20\"command\""
                  , "map" => "raw"
   },

   ["&" | Query] = lists:reverse(maps:fold(
      fun(K, V, Acc) -> [[K, "=", V], "&" | Acc] end,
      [],
      QueryParams)),

   iolist_to_binary([Remote, "/messages/", NID, "?", Query]).

open_stream(NID, {token, {ID, Key}}) ->
   URL = query_url(NID),
   SignReq = iolist_to_binary([ "GET\n", URL, "\n" ]),
   Signature = base64:encode(crypto:hmac(sha256, Key, SignReq)),

   open_stream2(URL, [{"Authorization", <<ID:(byte_size(ID))/binary, " ", Signature/binary>>}]);

open_stream(NID, {user,  {ID, Key}}) ->
   URL = query_url(NID),
   Auth = iolist_to_binary([ID, ":", Key]),

   open_stream2(URL, [{"Authorization", "Basic " ++ base64:encode(Auth)}]).

open_stream2(URL, Headers) ->
   Opts = [
      async,
      {stream_to, self()},
      {timeout, 10000},
      {recv_timeout, 15000}
   ],

   Headers2 = [{"User-Agent", ?USERAGENT} | Headers],

   {ok, Ref} = hackney:get(URL, Headers2, <<>>, Opts),

   receive
      {hackney_response, Ref, {status, 200, Reason}} ->
         io:format("GET ~s :: ~p/~p~n", [URL, 200, Reason]),
         receive {hackney_response, Ref, {headers, _}} ->
            receive {hackney_response, Ref, _Body} -> {ok, Ref}
            after 5000 -> {error, resp_timeout} end
         after 5000 -> {error, header_timeout} end;

      {hackney_response, Ref, {status, Status, Reason}} ->
         io:format("GET ~s :: ~p/~p~n", [URL, Status, Reason]),
         receive {hackney_response, Ref, <<Body/binary>>} -> {error, {http, {Status, Body}}}
         after 5000 -> {error, resp_timeout} end;

      {hackney_response, Ref, done} ->
         io:format("GET ~s :: EXIT~n", [URL]),
         {error, exit};

      Else ->
         io:format("GET ~s :: random: ~p", [URL, Else]),
         {error, exit}
   end.

handle_call(peek, _From, #{queue := Queue} = State) -> {reply, notify_queue:peek(Queue), State};
handle_call(queue, _From, State) -> {reply, {ok, maps:get(queue, State)}, State};
handle_call(stop, _From, State) -> {stop, normal, ok, State}.

handle_cast(_, State) -> {noreply, State}.








handle_info({update, Queue}, #{queue := Queue, nid := NID, timer := undefined} = State) ->
   io:format("chan:http[~s]: queue got new data ~n.", [Queue]),

   case try_push(NID, Queue) of
      ok            -> {noreply, State};
      {wait, Timer} -> {noreply, State#{timer := Timer}}
   end;

% Timer is active wait for retry to happen before pushing
handle_info({update, Queue}, #{queue := Queue} = State) ->
   {noreply, State};

handle_info(push_retry, #{queue := Queue, nid := NID, timer := Timer} = State) ->
   io:format("chan:http[~s]: retrying push~n.", [Queue]),

   case try_push(NID, Queue) of
      ok            ->
         {ok, cancel} = timer:cancel(Timer),
         {noreply, State};

      {wait, Timer} ->
         {noreply, State#{timer := Timer}}
   end;


handle_info(reconnect, #{queue := Queue, nid := NID} = State) ->
   io:format("chan:http[~s]: received reconnect request~n.", [Queue]),
   {ok, NewState} = query(NID, State),
   self() ! {update, Queue},
   {noreply, NewState};




handle_info({hackney_response, Ref, <<"\r\n">>}, #{clientref := Ref} = State) ->
   {noreply, State};

handle_info({hackney_response, Ref, done}, #{clientref := Ref} = State) ->
   io:format("chan:http[~s]: stream closed~n.", [maps:get(queue, State)]),
   self() ! reconnect,
   {noreply, State#{clientref := undefined}};

handle_info({hackney_response, Ref, Buf}, #{queue := Queue, clientref := Ref} = State) ->
   {ok, #{<<"proto/tm">> := Data}} = 'Elixir.Poison':decode(Buf),
   ForwardTo = maps:get(forward, State),
   Payload = base64:decode(Data),

   {ok, _}= notify_queue:add(ForwardTo, Payload),

   {noreply, State}.





try_push(NID, Queue) ->
   case notify_queue:peek(Queue) of
      {ok, {NowFmt, Buf} = Item} ->
         Res = push(NID, #{
            <<"proto/tm">> => base64:encode(Buf),
            <<"datetime">> => NowFmt
         }),

         case Res of
            {ok, Status} ->
               io:format("chan:http[~s]: popping item from queue: ~p~n.", [Queue, Status]),
               ok = notify_queue:pop(Queue, Item),
               try_push(NID, Queue);

            {wait, _Timer} = Res ->
               Res
         end;

      empty ->
         ok
   end.







terminate(_Reason, State) ->
   io:format("chan:http[~s]: channel closed~n.", [maps:get(queue, State)]),
   ok.

code_change(_OldVsn, _NewVsn, State) -> {ok, State}.






fibnit(Threshold) -> fib(0, 1, Threshold, []).
fib(A, B, T, Acc) when B < T -> fib(B, A + B, T, [A + B | Acc]);
fib(_A, _B, _T, Acc) -> lists:reverse(Acc).

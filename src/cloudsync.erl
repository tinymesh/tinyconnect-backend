-module(cloudsync).
-behaviour(gen_server).

% Handles message sync when there exists waiting data and there
% exists a "online" network uplink.

-export([
     start_link/1

   , sync/1

   , init/1
   , handle_call/3
   , handle_cast/2
   , handle_info/2
   , terminate/2
   , code_change/3
]).

sync(Server) ->
   gen_server:cast(Server, sync).

start_link(Queue) ->
   gen_server:start_link(?MODULE, [Queue], []).

init([QueueName]) ->
   File = application:get_env(tinyconnect, config_path, "/etc/tinyconnect.cfg"),
   Info = case file:consult(File) of
      {ok, [Network|_]} -> Network;
      {ok, []} -> undefined end,

   % this is how _handler_queue names queues, if you diden't know; now you do
   Queue = binary_to_atom(<<"queue#", (atom_to_binary(QueueName, utf8))/binary>>, utf8),
   {ok, _Q} = queue_manager:ensure(Queue, self()),
   ok = notify_queue:forward(Queue, self()),

   ok = sync(self),

   self() ! uploaded,

   {ok, #{
        queue => Queue
      , uplink => Info
      , stream => undefined
   }}.

handle_call(nil, _From, State) -> {noreply, State}.
handle_cast(sync, State) ->
   ok = flush(State),
   {noreply, State}.

handle_info(uploaded, #{uplink := Uplink,
                        stream := undefined} = State) ->
   {noreply, State#{stream => recv(Uplink)}};
handle_info(uploaded, #{} = State) ->
   {noreply, State};

handle_info({'DOWN', MonRef, process, Pid, _}, #{stream := {Pid, MonRef}} = State) ->
   error_logger:info_msg("stream: got down: ~p", [{Pid, MonRef}]),
   erlang:send_after(15000, self(), uploaded),
   {noreply, State#{stream => undefined}};
handle_info({'DOWN', _MonRef, process, _Pid, _}, #{stream := undefined} = State) ->
   error_logger:info_msg("stream: got down from undefined stream"),
   {noreply, State};


handle_info({'$notify_queue', {update, Queue}}, #{queue := Queue} = State) ->
   io:format("notified!!!!   ~s~n", [Queue]),
   ok = flush(State),
   {noreply, State}.

terminate(_Reason, _State) -> ok.

code_change(_OldVsn, _NewVsn, State) -> {ok, State}.


flush(#{queue := Queue} = State) ->
   case notify_queue:peek(Queue) of
      {ok, {When, What} = E} ->
         case upload(#{<<"datetime">> => When, <<"proto/tm">> => base64:encode(What)},
                     State) of
            ok ->
               notify_queue:pop(Queue, E),
               self() ! uploaded,
               flush(State);

            skip ->
               notify_queue:pop(Queue, E),
               flush(State);

            Err ->
               error_logger:error_msg("failed to upload msg: ~p~n", Err),
               notify_queue:pop(Queue, E),
               flush(State)
         end;

      {error, empty} ->
         ok
   end.

upload(_Payload, #{uplink := undefined}) -> skip;
upload(Payload, #{uplink := #{remote := Remote,
                              auth := {token, {Fprint, Key}}}}) ->

   io:format("lol: ~p~n", [Payload]),
   Body = jsx:encode([Payload]),
   Sig = base64:encode(crypto:hmac(sha256, Key, ["POST\n", Remote, "\n", Body])),
   Headers = [{"Authorization", [Fprint, " ", Sig]}],
   {ok, _Status, _Headers, Ref} = hackney:request(post, Remote, Headers, Body, []),

   io:format("lol: ~p~n", [hackney:body(Ref)]),

   ok.


recv(#{remote := Remote,
       auth := {token, {Fprint, Key}}} = Network) ->

   Sig = base64:encode(crypto:hmac(sha256, Key, ["GET\n", Remote, "\n", ""])),
   Headers = [{"Authorization", [Fprint, " ", Sig]}],

   Parent = self(),
   {_PID, _MonRef} = spawn_monitor(fun() ->
      case hackney:request(get, Remote, Headers, "", [async, {recv_timeout, 60000}]) of
         {ok, Ref} ->
            recvloop(Ref, wait, Network);

         {error, _} ->
            erlang:send_after(30000, Parent, uploaded),
            ok
      end
   end).

recvloop(Ref, wait, #{remote := Remote} = Network) ->
   receive
      {hackney_response, Ref, {status, 200, _}} ->
         error_logger:error_msg("cloudsync: connected to ~s~n", [Remote]),
         recvloop(Ref, headers, Network);

      {hackney_response, Ref, {status, _, _} = E} ->
         error_logger:error_msg("cloudsync: failed connect to ~s :: ~p~n", [Remote, E]),
         ok;

      {hackney_response, Ref, done} ->
         ok
   end;
recvloop(Ref, headers, Network) ->
   receive
      {hackney_response, Ref, {headers, _}} ->
         recvloop(Ref, recv, Network);

      {hackney_response, Ref, done} ->
         ok
   end;
recvloop(Ref, recv, #{serialport := ID} = Network) ->
   receive
      {hackney_response, Ref, done} ->
         ok;

      {hackney_response, Ref, <<Buf/binary>>} ->
         try
            case jsx:decode(Buf, [return_maps]) of
               #{<<"proto/tm">> := Proto} ->
                  tinyconnect:emit({data, #{id => ID,
                                            data => base64:decode(Proto),
                                            mod => ?MODULE,
                                            type => ?MODULE}}, ?MODULE),
                  recvloop(Ref, recv, Network);

               _ ->
                  recvloop(Ref, recv, Network)
            end
         catch _ ->
            recvloop(Ref, recv, Network)
         end;

      {hackney_response, Ref, X} ->
         io:format("got X: ~p~n", [X]),
         ok
   end.

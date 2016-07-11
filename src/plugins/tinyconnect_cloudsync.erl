-module(tinyconnect_cloudsync).
-behaviour(gen_server).

% takes direct input from other handlers, or possibly a notify_queue.
% All incoming data will eventually be sent to the remote server over
% HTTP.

-export([
     name/1
   , stop/1

   , start_link/2
   , init/1
   , handle_call/3
   , handle_cast/2
   , handle_info/2
   , terminate/2
   , code_change/3
]).

-export_type([def/0]).

-type channel() :: tinyconnect_channel:channel().
-type remote() :: binary().
-type token() :: {token, {ID :: binary(), Key :: binary()}}.

-type def() :: #{
   % http endpoint, will be used for both POST and GET
   remote => remote(),
   % Authentication
   auth   => token(),
   % input queues
   queues => [notify_queue:queue()],
   % INTERNAL; used to store the reference to active upstream conn
   stream => hackney:client_ref(),
   % what sources to subscribe to events from
   subscribe => [channel() | {channel(), [PlugName :: binary()]}],
   % the module to handle tty connections
   % name of plugin
   name => Name :: binary(),
   % opts for gen_server
   opts => Opts :: term(),
   start_after => [],
   % backoff for input stream
   recvbackoff => {TimerRef :: reference() | undefined, undefined | backoff:backoff()},
   % backoff for upload
   sendbackoff => {TimerRef :: reference() | undefined, undefined | backoff:backoff()},
   backoff => {TimerRef :: reference() | undefined, undefined | backoff:backoff()}
}.

default(_Chan) ->
   #{
      remote    => <<>>,
      auth      => undefined,
      subscribe => [],
      queues    => [],
      recvbackoff => {undefined, backoff:init(15000, 1800000)},
      sendbackoff => {undefined, backoff:init(15000, 1800000)}
    }.

%% plugin api

-spec name(pid()) -> {ok, Name :: binary()}.
name(Server) -> gen_server:call(Server, name).

-spec stop(pid()) -> ok.
stop(Server) -> gen_server:call(Server, stop).


%%%% gen_server implementation
%%%
-spec start_link(Chan :: channel(), def()) -> {ok, pid()} | {error, term()}.
start_link(Chan, PluginDef) ->
   Plugin = maps:merge(default(Chan), PluginDef),
   gen_server:start_link(?MODULE, [Chan, Plugin], []).

init([Chan, #{queues := Queues, name := Name} = Plugin]) ->
   lists:foreach(fun(Q) ->
      {ok, _Queue} = queue_manager:ensure(Q, undefined)
   end, Queues),

   ok = tinyconnect_channel:subscribe([Chan, Name], Plugin),
   ok = tinyconnect_channel:emit([Chan, Name], Plugin, open, #{pid => self()}),

   self() ! recvinit,

   {ok, Plugin}.


handle_call(stop, _From, State) -> {stop, normal, ok, State};
handle_call(name, _From, #{name := Name} = State) -> {reply, {ok, Name}, State}.

handle_cast(nil, State) -> {noreply, State}.

% handle normal input events, don't cache the event just assume we got
% it going
handle_info({'$tinyconnect',
            [Chan, _Plugin],
            #{type := data, data := Data} = Ev},
            #{channel := Chan} = State) ->

   {noreply, flush2(State, [{maps:get(at, Ev, undefined), Data}])};

% handle notify_queue input
handle_info({'$tinyconnect',
               [Chan, _Plugin],
               #{type := update, queue := Queue} = _Ev},
            #{channel := Chan} = State) ->
   {noreply, flush(State, Queue)};

handle_info({'$tinyconnect', _Res, _Ev}, State) -> {noreply, State};

%% Handle input/recv loop and flushing
handle_info({flush, Queue}, State) -> flush(State, Queue);
handle_info(recvinit, State) -> recv(State);

handle_info({hackney_response, Ref, {status, Status, _}},
            #{name := Name, remote := Remote, stream := Ref} = State) ->
   case State of
      #{recvbackoff := {Timer, Backoff}} when Status =:= 200 ->
         error_logger:info_msg("cloudsync[~s] connected ~s", [Name, Remote]),
         ok = cancel_timer(Timer),
         {_, NewBackoff} = backoff:succeed(Backoff),
         {noreply, State#{recvbackoff := NewBackoff}};

      #{recvbackoff := {Timer, Backoff}} ->
         error_logger:info_msg("cloudsync[~s] failed to connect ~s",
                               [Name, Remote]),
         ok = cancel_timer(Timer),
         {Delay, NewBackoff} = backoff:succeed(Backoff),
         NewTimer = erlang:send_after(Delay, recvinit, self()),
         {noreply, State#{recvbackoff => {NewTimer, NewBackoff}, stream => undefined}}
   end;

handle_info({hackney_response, Ref, {headers, _}}, #{stream := Ref} = State) ->
   {noreply, State};
handle_info({hackney_response, Ref, done},
            #{stream := Ref, recvbackoff := {undefined, Backoff}} = State) ->
   Delay = backoff:get(Backoff),
   Timer = erlang:send_after(Delay, recvinit, self()),

   {noreply, State#{stream => undefined, recvbackoff => {Timer, Backoff}}};

handle_info({hackney_response, Ref, <<Buf/binary>>},
            #{name := Name, channel := Chan, stream := Ref} = State) ->
   case jsx:decode(Buf, [return_maps]) of
      #{<<"proto/tm">> := Proto} ->
         Ev = #{data => base64:decode(Proto)},
         tinyconnect_channel:emit([Chan, Name], State, data, Ev),
         {noreply, State};

      _ ->
         {noreply, State}
   end.

terminate(_Reason, _State) -> ok.

code_change(_OldVsn, _NewVsn, State) -> {ok, State}.

recv(#{remote := Remote,
       auth := {token, {FPrint, Key}},
       recvbackoff := {Timer, Backoff}} = State) ->
   Sig = base64:encode(crypto:hmac(sha256, Key, ["GET\n", Remote, "\n", ""])),
   Headers = [{"Authorization", [FPrint, " ", Sig]}],

   ok = cancel_timer(Timer),

   case hackney:request(get, Remote, Headers, "", [async, {recv_timeout, 60000}]) of
      {ok, Ref} ->
         {_, NewBackoff} = backoff:succeed(Backoff),
         {noreply, State#{stream => Ref,
                          recvbackoff => {undefined, NewBackoff}}};

      {error, _} ->
         {Delay, NewBackoff} = backoff:fail(Backoff),
         NewTimer = erlang:send_after(Delay, recvinit, self()),
         {noreply, State#{stream => undefined,
                          recvbackoff => {NewTimer, NewBackoff}}}
   end.

flush(State, Queue) ->
   {ok, Items} = notify_queue:as_list(Queue),
   flush2(State,
          Items,
          fun(N, {Timer, Backoff}) ->
            notify_queue:shift(Queue, N),
            {_Delay, NewBackoff} = backoff:succeed(Backoff),
            cancel_timer(Timer),
            {undefined, NewBackoff}
          end,
          fun({Timer, Backoff}) ->
            {Delay, NewBackoff} = backoff:fail(Backoff),
            cancel_timer(Timer),
            NewTimer = erlang:send_after(Delay, flush, self()),
            {NewTimer, NewBackoff}
          end).

flush2(State, Items) ->
   flush2(State, Items, fun(_, {Timer, Backoff}) ->
      {_Delay, NewBackoff} = backoff:succeed(Backoff),
      cancel_timer(Timer),
      {undefined, NewBackoff}
   end).

flush2(State, Items, OnSuccess) ->
   flush2(State, Items, OnSuccess, fun({Timer, Backoff}) ->
      {_Delay, NewBackoff} = backoff:fail(Backoff),
      cancel_timer(Timer),
      {undefined, NewBackoff}
   end).
flush2(#{sendbackoff := Backoff} = State,
       Items,
       OnSuccess,
       OnError) ->

   case upload(Items, State) of
      {ok, N} ->
         State#{sendbackoff => OnSuccess(N, Backoff)};

      error ->
         State#{sendbackoff => OnError(Backoff)}
   end.

cancel_timer(undefined) -> ok;
cancel_timer(Ref) -> erlang:cancel_timer(Ref, [{async, true}]).

upload(Items, #{remote := Remote, auth := {token, {FPrint, Key}}}) ->
   Body = jsx:encode(lists:map(fun({_At, What}) -> #{<<"proto/tm">> => What} end, Items)),
   Sig = base64:encode(crypto:hmac(sha256, Key, ["POST\n", Remote, "\n",  Body])),
   Headers = [{"Authorization", [FPrint, " ", Sig]}],

   case hackney:request(post, Remote, Headers, Body, []) of
      {ok, 200, _Headers, Ref} ->
         {ok, Resp} = hackney:body(Ref),

         #{<<"saved">> := SavedItems} = jsx:decode(Resp, [return_maps]),
         {ok, length(SavedItems)};

      {ok, _, _, _} ->
         error;

      {error, _} ->
         error
   end.

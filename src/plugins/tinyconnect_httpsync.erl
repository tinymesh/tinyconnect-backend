-module(tinyconnect_httpsync).
-behaviour(gen_server).

-export([
     handle/2 % plugin handler

   , start_link/2
   , init/1
   , handle_call/3
   , handle_cast/2
   , handle_info/2
   , terminate/2
   , code_change/3

   , utc_datetime/1
]).

is_valid_uri(<<Remote/binary>>) ->
   case http_uri:parse(binary_to_list(Remote)) of
      {ok, {_Scheme, _UserInfo, _Host, _Port, _Path, _Query}} -> ok;
      {ok, {_Scheme, _UserInfo, _Host, _Port, _Path, _Query, _Fragment}} -> ok;
      {error, E} -> {error, E}
   end.

args(Def, Args) -> args(Def, Args, #{}).
args(_Def, [], Args) when map_size(Args) =:= 0 -> ok;
args(_Def, [], Args) when map_size(Args) > 0 -> {args, Args};
args(Def, [Arg | Rest], Args) ->
   case get_in(Arg, Def) of
      undefined -> args(Def, Rest, maps:put(Arg, <<"required argument">>, Args));
      _ -> args(Def, Rest, Args)
   end.

get_in([], Arg) -> Arg;
get_in([{H, Def} | T], Arg) when is_map(Arg) -> get_in(T, maps:get(H, Arg, Def));
get_in([H | T], Arg) when is_map(Arg) -> get_in([{H, undefined} | T], Arg);
get_in([_H | _T], _Arg) -> undefined.

handle({start, ChannelName, PluginDef}, _State) ->
   case args(PluginDef, [ [<<"remote">>],
                          [<<"auth">>, <<"fingerprint">>],
                          [<<"auth">>, <<"key">>] ] ) of
      ok ->
         case is_valid_uri(maps:get(<<"remote">>, PluginDef)) of
            ok ->
               gen_server:start_link(?MODULE, [ChannelName, PluginDef], []);

            {error, E} ->
               {error, {args, #{<<"remote">> => E}}}
         end;

      {args, Args}->
         {error, {args, Args}}
   end;

handle(_, nostate) -> ok;

handle({event, input, <<Buf/binary>>, _Meta}, Server) ->
   gen_server:call(Server, {input, utc_datetime(erlang:timestamp()), Buf});
handle({event, queue, QueueItems, _Meta}, Server) ->
   gen_server:call(Server, {queue, QueueItems}).


start_link(Chan, PluginDef) ->
   gen_server:start_link(?MODULE, [Chan, PluginDef], []).

init([Chan, #{<<"id">> := ID} = PluginDef]) ->

   self() ! reconnect,

   {ok, #{
      channel => Chan,
      id => ID,
      incoming => [],
      remote => undefined,
      definition => PluginDef,
      recv => {undefined, undefined, backoff:init(15000, 1800000)},
      flush => {undefined, backoff:init(15000, 1800000)}
   }}.

handle_call({input, Datetime, Buf}, _From, #{incoming := Incoming, id := _ID, channel := _Channel} = State) ->
   Incoming2 = unique([{Datetime, Buf} | Incoming]),
   #{incoming := NewIn} = NewState = flush(State#{incoming => Incoming2}),

   Forwarded = Incoming2 -- NewIn,

   %% emit call handles root level events
   %ok = tinyconnect_channel2:emit({global, Channel}, ID, forwarded, Forwarded),

   % {emit, ...} handels events in the middle of a pipeline
   {reply,
     {emit, forwarded, Forwarded, self()},
      NewState};

handle_call({queue, Items}, _From, #{incoming := Incoming, id := _ID, channel := _Channel} = State) ->
   Incoming2 = unique(Incoming ++ Items),
   #{incoming := NewIn} = NewState = flush(State#{incoming => Incoming2}),

   Forwarded = Incoming2 -- NewIn,

   %% emit call handles root level events
   %ok = tinyconnect_channel2:emit({global, Channel}, ID, forwarded, Forwarded),

   % {emit, ...} handels events in the middle of a pipeline
   Reply = {emit, forwarded, Forwarded, self()},
   {reply, Reply, NewState};

handle_call(stop, _From, State) ->
   {stop, normal, ok, State}.

handle_cast(_, State) -> {noreply, State}.

handle_info(flush, State) ->
   {noreply, flush(State)};
handle_info(reconnect, State) ->
   {noreply, recv(State)};

handle_info({hackney_response, Ref, {error, {closed, Reason}}},
            #{recv := {Ref, _, _}} = State) ->
   lager:warning("httpsync: recv stream closed ~p", [Reason]),
   {stop, normal, State};

handle_info({hackney_response, Ref, {status, Status, _}},
            #{recv := {Ref, _, _}, definition := #{<<"remote">> := Remote}} = State) ->

   case State of
      #{recv := {_, Timer, Backoff}} when Status =:= 200 ->
         lager:info("httpsync: connected ~s (HTTP ~p)", [Remote, Status]),
         ok = cancel_timer(Timer),
         {_, NewBackoff} = backoff:succeed(Backoff),
         {noreply, State#{recv => {Ref, undefined, NewBackoff}}};

      #{recv := {_, Timer, Backoff}} ->
         lager:warning("httpsync: failed to connect ~s (HTTP ~p)", [Remote, Status]),
         ok = cancel_timer(Timer),
         {Delay, NewBackoff} = backoff:fail(Backoff),
         NewTimer = erlang:send_after(Delay, reconnect, self()),
         {noreply, State#{recv => {undefined, NewTimer, NewBackoff}}}
   end;

handle_info({hackney_response, Ref, {headers, _}}, #{recv := {Ref, _, _}} = State) ->
   {noreply, State};

handle_info({hackney_response, Ref, done},
            #{recv := {Ref, Timer, Backoff}} = State) ->
   Delay = backoff:get(Backoff),
   Timer = erlang:send_after(Delay, reconnect, self()),

   {noreply, State#{recv => {undefined, Timer, Backoff}}};

handle_info({hackney_response, Ref, <<Buf/binary>>},
            #{recv := {Ref, _, _}, channel := Channel, id := ID} = State) ->

   case jsx:decode(Buf, [return_maps]) of
      #{<<"proto/tm">> := Proto} ->
         lager:debug("httpsync: recv ~p", [base64:decode(Proto)]),
         ok = tinyconnect_channel2:emit({global, Channel}, ID, input, base64:decode(Proto)),
         {noreply, State};

      _ ->
         {noreply, State}
   end.

terminate(Reason, _State) ->
   _ = lager:debug("httpsync: terminated\n\treason: ~p", [Reason]),
   ok.

code_change(_OldVsn, _NewVsn, State) -> {ok, State}.

flush(#{incoming := Incoming, flush := {Timer, Backoff}} = State) ->
   _ = lager:debug("httpsync: flushing ~p items", [length(Incoming)]),

   ok = cancel_timer(Timer),

   case upload(Incoming, State) of
      error ->
         {Delay, NewBackoff} = backoff:succeed(Backoff),
         NewTimer = erlang:send_after(Delay, flush, self()),
         State#{flush => {NewTimer, NewBackoff}};

      {ok, Saved} ->
         {_, NewBackoff} = backoff:succeed(Backoff),
         {_Saved, Rest} = lists:split(length(Saved), Incoming),
         State#{incoming => Rest, flush => {undefined, NewBackoff}}
   end.

upload(Items, #{definition := PlugDef}) ->
   #{<<"remote">> := Remote, <<"auth">> := Auth} = PlugDef,
   #{<<"fingerprint">> := FPrint, <<"key">> := Key} = Auth,
   Body = jsx:encode(lists:map(fun({At, What}) ->
      #{<<"proto/tm">> => base64:encode(What),
        <<"datetime">> => At}
   end, Items)),

   Sig = base64:encode(crypto:hmac(sha256, Key, ["POST\n", Remote, "\n", Body])),
   Headers = [{"Authorization", [FPrint, " ", Sig]}],

   case hackney:request(post, Remote, Headers, Body, []) of
      {ok, Code, _Headers, Ref} when Code =:= 200; Code =:= 201 ->
         {ok, Resp} = hackney:body(Ref),
         #{<<"saved">> := SavedItems} = jsx:decode(Resp, [return_maps]),
         {ok, SavedItems};

      {ok, Code, _Headers, Ref} ->
         lager:debug("httpsync: unknown status ~p\nbody: ~p",
            [Code, hackney:body(Ref)]),
         error;

      {error, Err} ->
         lager:debug("httpsync: error ~p", [Err]),
         error
   end.

recv(#{definition := PlugDef, recv := {Stream, Timer, Backoff}} = State) ->
   #{<<"remote">> := Remote, <<"auth">> := Auth} = PlugDef,
   #{<<"fingerprint">> := FPrint, <<"key">> := Key} = Auth,

   Sig = base64:encode(crypto:hmac(sha256, Key, ["GET\n", Remote, "\n", ""])),
   Headers = [{"Authorization", [FPrint, " ", Sig]}],

   ok = cancel_timer(Timer),

   case hackney:request(get, Remote, Headers, "", [async, {recv_timeout, 120000}]) of
      {ok, Ref} ->
         {_, NewBackoff} = backoff:succeed(Backoff),
         State#{recv => {Ref, undefined, NewBackoff}};

      {error, E} ->
         {Delay, NewBackoff} = backoff:fail(Backoff),
         lager:error("httpsync: failed to open recv stream\n\treason: ~p", [E]),
         NewTimer = erlang:send_after(Delay, reconnect, self()),
         State#{recv => {Stream, NewTimer, NewBackoff}}
   end.

cancel_timer(undefined) -> ok;
cancel_timer(Ref) -> erlang:cancel_timer(Ref, [{async, true}]).

utc_datetime(TS = {_, _, Micro}) ->
    {{Year, Month, Day}, {Hour, Minute, Second}} = calendar:now_to_universal_time(TS),
    iolist_to_binary(io_lib:format("~4w-~2..0w-~2..0wT~2w:~2..0w:~2..0w.~6..0wZ",
		  [Year,Month,Day,Hour,Minute,Second,Micro])).


unique(L) -> unique([], L).
unique(R, []) -> R;
unique(R, [H | T]) ->
   case member_remove(H, T, [], true) of
      {false, Nt} -> unique(R, Nt);
      {true, Nt} -> unique([H | R], Nt)
   end.

member_remove(_, [], Res, Bool) -> {Bool, Res};
member_remove(H, [H | T], Res,_) -> member_remove(H, T, Res, false);
member_remove(H, [V | T], Res, Bool) -> member_remove(H, T, [V | Res], Bool).

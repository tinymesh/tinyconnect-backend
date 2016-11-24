-module(tinyconnect_tty2).
-behaviour(gen_fsm).

-export([
     handle/2 % plugin handler

   , init/1
   , handle_event/3
   , handle_sync_event/4
   , handle_info/3
   , terminate/3
   , code_change/4

   , open/2
   , io/2, io/3
   , stop/2
]).

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

handle({start, ChannelName, #{} = Def}, _State) ->
   % require: path, id, options, options.baud, options.flow_control
   case args(Def, [ [<<"path">>],
               [<<"id">>],
               [<<"options">>, <<"baud">>],
               [<<"options">>, <<"flow_control">>] ]) of

      ok           -> gen_fsm:start_link(?MODULE, [ChannelName, Def], []);
      {args, Args} -> {error, {args, Args}}
   end;

handle(serialize, nostate) -> {ok, <<"incomplete">>};
handle(_, nostate) -> ok;

handle({update, PortDef, #{<<"channel">> := Channel}}, Server) ->
   ok = gen_fsm:sync_send_all_state_event(Server, stop),
   case handle({start, Channel, PortDef}, nostate) of
      {ok, PID} -> {state, PID, PortDef}
   end;


handle(Ev = serialize, Server) ->
   gen_fsm:sync_send_all_state_event(Server, Ev);

handle({event, input, <<Buf/binary>>, _Meta}, Server) ->
   gen_fsm:sync_send_event(Server, {write, Buf}).


% backedoff retry TTY start
open(connect, #{<<"path">> := Path,
                <<"options">> := PortOpts} = State) ->
   NewBackoff = maps:get(<<"backoff">>, State, 1) * 2.75,
   NewState = maps:put(<<"backoff">>, min(NewBackoff, 120), State),

   case (catch gen_serial:open(binary_to_list(Path), PortOpts)) of
      {ok, PortRef} ->
         _ = lager:info("tty2: open ~s", [Path]),
         {next_state, io, maps:put(<<"portref">>, PortRef, NewState)};


      {error, {exit, {signal, 11}}} ->
         _ = lager:info("tty2: open ~s ERR: ~s", [Path, "EACCESS"]),
         gen_fsm:send_event_after(trunc(NewBackoff * 1000), connect),
         {next_state, open, maps:put(<<"portref">>, {error, eaccess}, NewState)};

      {error, {_, [H|_] = Err}} when is_integer(H); is_binary(H); is_list(H) ->
         gen_fsm:send_event_after(trunc(NewBackoff * 1000), connect),
         _ = lager:info("tty2: open ~s ERR: ~s", [Path, Err]),
         Str = iolist_to_binary([<<"error: ">>, Err]),
         {next_state, open, maps:put(<<"portref">>, {error, Str}, NewState)};

      {error, Err} ->
         _ = lager:info("tty2: open ~s ERR: ~p", [Path, Err]),
         gen_fsm:send_event_after(trunc(NewBackoff * 1000), connect),
         {next_state, open, maps:put(<<"portref">>, {error, Err}, NewState)}
   end.

io({serial, _Port, Buf},
   #{<<"channel">> := Channel, <<"id">> := ID} = State) ->
   _ = lager:debug("tty2: recv ~s : ~p", [maps:get(<<"path">>, State), Buf]),
   ok = tinyconnect_channel2:emit({global, Channel}, ID, input, Buf),
   {next_state, io, State, hibernate};

io({write, <<Buf/binary>>}, #{<<"portref">> := Port} = State) ->
   _ = lager:debug("tty2: write ~s : ~p", [maps:get(<<"path">>, State), Buf]),
   ok = gen_serial:bsend(Port, Buf, 1000),
   {next_state, io, State, hibernate};

io({serial_closed, Port}, #{<<"portref">> := Port} = State) ->
   _ = lager:info("tty: serial port closed (~s)", [maps:get(<<"path">>, State)]),
   % send a retry attempt, in the meantime portref is nil
   gen_fsm:send_event_after(0, connect),
   {next_state, open, State#{<<"portref">> => {error, enoent}}, hibernate}.

io({write, <<Buf/binary>>}, From, #{<<"portref">> := Port} = State) ->
   _ = lager:debug("tty2: write ~s : ~p", [maps:get(<<"path">>, State), Buf]),
   ok = gen_serial:bsend(Port, Buf, 1000),
   _ = gen_fsm:reply(From, ok),
   {next_state, io, State, hibernate}.

stop(Ev, State) ->
   {stop, Ev, State}.

init([Chan, #{<<"path">> := Path,
              <<"id">> := ID,
              <<"options">> := Opts}]) ->
   _ = lager:debug("opening up tty ~s with opts ~p", [Path, unserialize_opts(maps:to_list(Opts))]),
   ok = gen_fsm:send_event(self(), connect),
   NewOpts = orddict:merge(fun(_, _A, B) -> B end,
                           orddict:from_list([{active, true}, {packet, none}, {baud, 19200}, {flow_control, none}]),
                           orddict:from_list(unserialize_opts(maps:to_list(Opts)))),

   {ok, open, #{<<"channel">> => Chan,
                <<"id">> => ID,
                <<"path">> => Path,
                <<"options">> => NewOpts}}.

unserialize_opts(Opts) -> unserialize_opts(Opts, []).

unserialize_opts([], Acc) -> Acc;

unserialize_opts([{<<"active">>, Active} | Rest], Acc) ->
   unserialize_opts(Rest, [{active, Active} | Acc]);
unserialize_opts([{<<"packet">>, Packet} | Rest], Acc) ->
   unserialize_opts(Rest, [{packet, binary_to_atom(Packet, utf8)} | Acc]);
unserialize_opts([{<<"baud">>, Baud} | Rest], Acc) ->
   unserialize_opts(Rest, [{baud, Baud} | Acc]);
unserialize_opts([{<<"flow_control">>, FlowCtrl} | Rest], Acc) ->
   unserialize_opts(Rest, [{flow_control, binary_to_atom(FlowCtrl, utf8)} | Acc]).


handle_event(_, StateName, State) -> {next_state, StateName, State, hibernate}.

handle_sync_event(serialize, _From, StateName, State) ->
   case maps:get(<<"portref">>, State, undefined) of
      {error, <<E/binary>>} ->
         {reply, {ok, #{<<"error">> => #{<<"msg">> => E}}}, StateName, State, hibernate};

      {error, Code} when is_atom(Code) ->
         {reply, {ok, #{<<"error">> => #{<<"code">> => Code}}}, StateName, State, hibernate};

      {error, _} ->
         {reply, {ok, #{<<"error">> => #{<<"msg">> => <<"undefined error">>}}}, StateName, State, hibernate};

      _S ->
         {reply, {ok, <<"alive">>}, StateName, State, hibernate}
   end;
handle_sync_event(stop, _From, _StateName, #{<<"portref">> := _Port, <<"path">> := Path} = State) ->
   _ = lager:info("tty2: close ~s", [Path]),
   {stop, normal, ok, State}.

handle_info(Info, StateName, State) ->
   ?MODULE:StateName(Info, State).

terminate(normal, _FSM, _State) -> ok;
terminate(_Reason, _FSM, _State) -> ok.

code_change(_OldVsn, StateName, Data, _Extra) -> {ok, StateName, Data}.

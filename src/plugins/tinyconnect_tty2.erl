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

handle({start, ChannelName, PluginDef}, _State) ->
   gen_fsm:start_link(?MODULE, [ChannelName, PluginDef], []);

handle(Ev = serialize, Server) ->
   gen_fsm:sync_send_all_state_event(Server, Ev);

handle({event, input, <<Buf/binary>>, _Meta}, Server) ->
   gen_fsm:sync_send_event(Server, {write, Buf}).


% backedoff retry TTY start
open(connect, #{<<"path">> := Path,
                <<"options">> := PortOpts} = State) ->
   Backoff = maps:get(<<"backoff">>, State, 1) * 2.75,
   NewState = maps:put(<<"backoff">>, min(Backoff, 120), State),

   case gen_serial:open(Path, PortOpts) of
      {ok, PortRef} ->
         {next_state, io, maps:put(<<"state">>, PortRef, NewState)};

      {error, {exit, {signal, 11}}} ->
         gen_fsm:send_event_after(trunc(Backoff * 1000), open),
         {next_state, open, maps:put(<<"state">>, <<"error: eaccess">>), NewState};

      {error, {_, Err}} when is_list(Err) ->
         gen_fsm:send_event_after(trunc(Backoff * 1000), open),
         Str = iolist_to_binary([<<"error: ">>, Err]),
         {next_state, open, maps:put(<<"state">>, Str), NewState};

      {error, Err} ->
         gen_fsm:send_event_after(trunc(Backoff * 1000), open),
         {next_state, open, maps:put(<<"state">>, Err), NewState}
   end.
%open(_Ev, State) ->
%   Backoff = maps:get(<<"backoff">>, State, 1) * 2.75,
%   NewState = maps:put(<<"backoff">>, min(Backoff, 120), State),
%   gen_fsm:send_event_after(trunc(Backoff * 1000), open),
%   {next_state, io, NewState, hibernate}.

io({serial, _Port, Buf},
   #{<<"channel">> := Channel, <<"id">> := ID} = State) ->
   ok = tinyconnect_channel2:emit({global, Channel}, ID, input, Buf),
   io:format("hello i'm a serialport!!!! got buf ~p ~n~n~n", [Buf]),
   {next_state, io, State, hibernate};
io({write, <<Buf/binary>>}, #{<<"state">> := Port} = State) ->
   ok = gen_serial:bsend(Port, Buf, 1000),
   {next_state, io, State, hibernate}.

io({write, <<Buf/binary>>}, From, #{<<"state">> := Port} = State) ->
   ok = gen_serial:bsend(Port, Buf, 1000),
   _ = gen_fsm:reply(From, ok),
   {next_state, io, State, hibernate}.

stop(Ev, State) ->
   {stop, Ev, State}.

init([Chan, #{<<"port">> := Path,
              <<"id">> := ID,
              <<"options">> := Opts}]) ->
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
   {reply, {ok, nil}, StateName, State, hibernate}.

handle_info(Info, StateName, State) ->
   ?MODULE:StateName(Info, State).

terminate(normal, _FSM, _State) -> ok;
terminate(_Reason, _FSM, _State) -> ok.

code_change(_OldVsn, StateName, Data, _Extra) -> {ok, StateName, Data}.

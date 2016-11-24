-module(tinyconnect_udp).
-behaviour(gen_server).

-export([
     handle/2 % plugin handler

   , init/1
   , handle_call/3
   , handle_cast/2
   , handle_info/2

   , terminate/2
   , code_change/3
]).

handle({start, ChannelName, #{<<"remote">> := _Remote} = PluginDef}, _State) ->
   gen_server:start_link(?MODULE, [ChannelName, PluginDef], []);
handle({start, _ChannelName, #{} = _PluginDef}, _State) ->
   ok;

handle(_, nostate) -> ok;


handle(Ev = serialize, Server) ->
   gen_server:call(Server, Ev);

handle({event, input, <<_Buf/binary>>, _Meta} = Ev, Server) ->
   gen_server:call(Server, Ev).

init([Chan, #{<<"remote">> := Remote} = PlugDef]) ->
   _ = lager:info("udp: remote ~s", [maps:get(<<"remote">>, PlugDef)]),
   {Host, Port} = case lists:reverse(binary:split(Remote, <<":">>, [global])) of
      [P] -> {<<"::1">>, binary_to_integer(P)};
      [P | A] ->
         A2 = join(lists:reverse(A), <<":">>),
         {A2, binary_to_integer(P)}
   end,
   _ = lager:info("udp: open ~s :~p", [Host, Port]),

   {Host2, SockOpts} = parsehost(Host),

   {ok, Socket} = gen_udp:open(0, [binary, {active, true} | SockOpts]),
   PlugDef2 = maps:put(<<"channel">>, Chan, PlugDef),
   PlugDef3 = maps:put(<<"socket">>, Socket, PlugDef2),
   PlugDef4 = maps:put(<<"host">>, Host2, PlugDef3),
   PlugDef5 = maps:put(<<"port">>, Port, PlugDef4),
   {ok, PlugDef5}.

parsehost(<<BinHost/binary>>) ->
   Host = binary_to_list(BinHost),
   case inet:parse_ipv6strict_address(Host) of
      {error, einval} ->
         case inet:parse_ipv4strict_address(Host) of
            {error, einval} -> {Host, [inet, inet6]};
            {ok, Addr} -> {Addr, [inet]}
         end;

      {ok, Addr} -> {Addr, [inet6]}
   end.


handle_call(serialize, _From, State) -> {reply, {ok, State}, State};

handle_call({event, input, <<Buf/binary>>, _Meta}, _From, #{} = State) ->
   #{<<"remote">> := Remote,
     <<"host">> := Host,
     <<"port">> := Port,
     <<"socket">> := Socket} = State,

   _ = lager:debug("udp: send ~s : ~p", [Remote, Buf]),
   case gen_udp:send(Socket, Host, Port, Buf) of
      ok ->
         {reply, ok, State};

      {error, Err} ->
         _ = lager:debug("udp: failed to send ~s : ~p", [Remote, Err]),
         {reply, ok, State}
   end;


handle_call(stop, _From, State) -> {stop, normal, State}.

handle_cast(nil, State) -> {noreply, State}.

handle_info({udp, Sock, _, _, <<Buf/binary>>}, #{<<"socket">> := Sock,
                                                 <<"remote">> := Remote,
                                                 <<"channel">> := Chan,
                                                 <<"id">> := ID} = State) ->
   _ = lager:debug("udp: recv ~s : ~p", [Remote, Buf]),
   tinyconnect_channel2:emit({global, Chan}, ID, input, Buf),
   {noreply, State};
handle_info(nil, State) -> {noreply, State}.

terminate(Reason, _State) ->
   'Elixir.IO':inspect(["udp terminated!!!", Reason]),
   ok.

code_change(_OldVsn, _NewVsn, State) -> {ok, State}.



join([], _Sep) -> <<>>;
join([Part], _Sep) -> Part;
join([Head|Tail], Sep) ->
  lists:foldl(fun(Value, Acc) -> <<Acc/binary, Sep/binary, Value/binary>> end, Head, Tail).



-module(tinyconnect_pty).
-behaviour(gen_server).

% PTY plugin
%
% Opens a PTY that external software can use to communicate with.
% One typical use case would be to open a PTY and forward all traffic to a
% serialport, sniffing data in between.
%
% Requires:
%  - linux (may work in cygwin)
%  - socat

-export([
     handle/2
   , init/1
   , handle_call/3
   , handle_cast/2
   , handle_info/2
   , terminate/2
   , code_change/3
]).

handle({start, ChannelName, PluginDef}, _State) ->
   gen_server:start_link(?MODULE, [ChannelName, PluginDef], []);

handle(Ev = serialize, Server) ->
   gen_server:call(Server, Ev);

handle({event, input, <<_Buf/binary>>, _Meta} = Ev, Server) ->
   gen_server:call(Server, Ev).

init([Chan, #{} = PlugDef]) ->
   case find_socat() of
      {[_|_] = Exec, Env} ->
         ok = mklinkdir(PlugDef),
         _ = lager:info("pty: open ~s ~s ~s", [Exec,
            maybe_link(<<"PTY,raw">>, PlugDef), <<"-">>]),

         Port = erlang:open_port({spawn_executable, Exec}, [
              {env, Env}
            , binary
            , exit_status
            , {args, [maybe_link(<<"PTY,raw">>, PlugDef), <<"-">>]}]),

         _ = lager:info("pty: open ~s", [maybe_link(<<"">>, PlugDef)]),

         PlugDef2 = maps:put(<<"port">>, Port, PlugDef),
         PlugDef3 = maps:put(<<"channel">>, Chan, PlugDef2),
         {ok, PlugDef3}
   end.



mklinkdir(#{<<"link">> := Link}) ->
   _ = lists:foldl(fun(Seg, Acc) ->
      case file:make_dir(filename:join(Acc ++ [Seg])) of
         {error, eexist} -> Acc ++ [Seg];
         ok -> Acc ++ [Seg]
      end
   end, [], filename:split(filename:dirname(Link))),
   ok;
mklinkdir(#{}) -> ok.

find_socat() ->
   case os:getenv("TINYCONNECT_BINDIR") of
      false -> {os:find_executable("socat"), []};
      Path -> {filename:join(Path, "socat"), [{"LD_LIBRARY_PATH", Path}]}
   end.

maybe_link(Arg, #{<<"link">> := Link}) -> <<Arg/binary, ",link=", Link/binary>>;
maybe_link(Arg, #{}) -> Arg.



handle_call(serialize, _From, #{<<"port">> := Port} = State) when Port =/= undefined ->
   {reply, {ok, <<"alive">>}, State};
handle_call(serialize, _From, #{} = State) ->
   {reply, {ok, <<"unknown">>}, State};
handle_call({event, input, <<Buf/binary>>, _Meta}, _From, #{<<"port">> := Port} = State) ->
   #{<<"link">> := Path} = State,
   _ = lager:debug("pty: send ~s : ~p", [Path, Buf]),
   true = erlang:port_command(Port, Buf),
   {reply, ok, State};
handle_call(stop, _From, State) -> {stop, normal, State}.

handle_cast(nil, State) -> {noreply, State}.

handle_info({_Port, {data, Input}}, #{<<"link">> := Path,
                                      <<"channel">> := Chan,
                                      <<"id">> := ID} = State) ->
   _ = lager:debug("pty: recv ~s : ~p", [Path, Input]),
   tinyconnect_channel2:emit({global, Chan}, ID, input, Input),
   {noreply, State};

handle_info({_Port, {exit_status, _}}, State) ->
   {noreply, maps:put(<<"port">>, undefined, State)}.

terminate(_Reason, _State) -> ok.

code_change(_OldVsn, _NewVsn, State) -> {ok, State}.

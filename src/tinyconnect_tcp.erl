-module(tinyconnect_tcp).
-behaviour(gen_server).

-export([
     start_link/2

   , init/1
   , handle_call/3
   , handle_cast/2
   , handle_info/2
   , terminate/2
   , code_change/3
]).

start_link(NID, PortID) ->
   RegName = binary_to_atom(<<"upstream:", NID/binary>>, utf8),
   gen_server:start_link({local, RegName}, ?MODULE, [NID, PortID], []).

init([NID, PortID]) ->
   Opts = [binary, {packet, raw}],
	{Remote, Port} = case string:tokens(application:get_env(tinyconnect, remote, "tcp.cloud-ng.tiny-mesh.com:7001"), ":") of
		[Rem] -> {Rem, 7001};
		[Rem, PortStr] -> {Rem, list_to_integer(PortStr)}
	end,
   case gen_tcp:connect(Remote, Port, Opts) of
      {ok, Socket} ->
         io:format("conn[~p]: connected ~p~n", [self(), Socket]),
         ok = maybe_create_pg2_group(NID),
         ok = maybe_create_pg2_group(<<"port:", (atom_to_binary(PortID, utf8))/binary>>),

         ok = tinyconnect_tty_ports:update(PortID, #{conn => true}),

         {ok, #{
              sock => Socket
            , nid => NID
            , id => PortID
         }};

      {error, _Err} = Res ->
         Res
   end.

handle_call(stop, _From, State) -> {stop, normal, ok, State};
handle_call(nil, _From, State) -> {noreply, State}.

handle_cast(nil, State) -> {noreply, State}.

handle_info({bus, {_PID, {_PortID, _NID}, upstream}, _Buf}, #{} = State) ->
   {noreply, State};

handle_info({bus, {_PID, {_PortID, _NID}, downstream}, Buf}, #{sock := Sock} = State) ->
   ok = gen_tcp:send(Sock, Buf),
   {noreply, State};

handle_info({tcp, _Port, Buf}, #{nid := NID, id := PortID} = State) ->
   Items = pg2:get_members(<<"nid:", NID/binary>>) ++ pg2:get_members(<<"port:", (atom_to_binary(PortID, utf8))/binary>>),
   io:format("ship/tcp -> [~p] -> ~p~n", [Items, Buf]),
   lists:foreach(fun(PID) -> PID ! {bus, {self(), {PortID, NID}, upstream}, Buf} end, Items),
   {noreply, State}.

terminate(_Reason, #{sock := Sock, id := ID}) ->
   ok = tinyconnect_tty_ports:update(ID, #{conn => false}),
   _ = gen_tcp:close(Sock).

code_change(_OldVsn, _NewVsn, State) -> {ok, State}.

maybe_create_pg2_group(Group) ->
   case pg2:join(Group, self()) of
      {error, {no_such_group, Group}} ->
         ok = pg2:create(Group),
         pg2:join(Group, self());

      ok ->
         ok
   end.



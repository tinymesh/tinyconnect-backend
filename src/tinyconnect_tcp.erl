-module(tinyconnect_tcp).
-behaviour(gen_server).

-export([
     start_link/1

   , init/1
   , handle_call/3
   , handle_cast/2
   , handle_info/2
   , terminate/2
   , code_change/3
]).

start_link(NID) ->
   RegName = binary_to_atom(<<"upstream:", NID/binary>>, utf8),
   gen_server:start_link({local, RegName}, ?MODULE, [NID], []).

init([NID]) ->
   Opts = [binary, {packet, raw}],
   case gen_tcp:connect("tcp.cloud-ng.tiny-mesh.com", 7001, Opts) of
      {ok, Socket} ->
         ok = maybe_create_pg2_group(NID),

         {ok, #{
              sock => Socket
            , nid => NID
         }};

      {error, _Err} = Res ->
         Res
   end.

handle_call(nil, _From, State) -> {noreply, State}.

handle_cast(nil, State) -> {noreply, State}.

handle_info({bus, {_PID, _NID, upstream}, _Buf}, #{} = State) ->
   {noreply, State};

handle_info({bus, {_PID, _NID, downstream}, Buf}, #{sock := Sock} = State) ->
   io:format(" tcp/send: ~p~n", [Buf]),
   ok = gen_tcp:send(Sock, Buf),
   {noreply, State};

handle_info({tcp, _Port, Buf}, #{nid := NID} = State) ->
   Items = pg2:get_members(NID),
   io:format(" tcp/recv: ~p~n", [Buf]),
   lists:foreach(fun(PID) -> PID ! {bus, {self(), NID, upstream}, Buf} end, Items),
   {noreply, State}.

terminate(_Reason, #{sock := Sock}) ->
   ok = gen_tcp:close(Sock).

code_change(_OldVsn, _NewVsn, State) -> {ok, State}.

maybe_create_pg2_group(Group) ->
   case pg2:join(Group, self()) of
      {error, {no_such_group, Group}} ->
         ok = pg2:create(Group),
         pg2:join(Group, self());

      ok ->
         ok
   end.



-module(tinyconnect_tty).
-behaviour(gen_server).

-export([
     start_link/1

   , send/2
   , stealport/1
   , releaseport/2

   , stop/0
   , stop/1

   , init/1
   , handle_call/3
   , handle_cast/2
   , handle_info/2
   , terminate/2
   , code_change/3
]).

start_link(<<Port/binary>>) ->
   RegName = binary_to_atom(<<"downstream:", Port/binary>>, utf8),
   gen_server:start_link({local, RegName}, ?MODULE, [Port], []).

send(Who, Buf) ->
   case pg2:get_members(Who) of
      {error, {no_such_group, _}} = Err ->
         Err;

      Members ->
         lists:foreach(fun(PID) ->
            PID ! {bus, {self(), Who, upstream}, Buf}
         end, Members)
   end.

stealport(Server) ->
   {ok, Port} = gen_server:call(Server, steal),
   ok = gen_serial:set_owner(Port),
   {ok, Port}.

releaseport(Port, Server) ->
   ok = gen_serial:set_owner(Port, Server).

stop()       -> stop(?MODULE).
stop(Server) -> gen_server:call(Server, stop).

init([Path]) ->
   Path2 = binary_to_list(Path),
   Opts = [{active, once}, {packet, none}, {baud, 19200}, {flow_control, none}],

	case gen_serial:open(Path2, Opts) of
   	{ok, Ref} ->
			case tinyconnect_config:identify(Ref) of
				{error, timeout} ->
               _ = gen_serial:close(Ref),
					{error, 'identify-timeout'};

				{ok, {0, _SID, _UID}} ->
               _ = gen_serial:close(Ref),
					io:format("tty[~p]: unconfigured ~p~n", [self(), Path]),
					{error, nid};

				{ok, {NID, SID, UID}} ->
					io:format("tty[~p]: connected ~p~n", [self(), {NID, SID, UID}]),

					B64NID = integer_to_binary(NID, 36),
					ok = maybe_create_pg2_group(B64NID),

					{ok, Conn} = tinyconnect_tcp:start_link(B64NID, Path),

					ok = tinyconnect_tty_ports:update(Path, #{uart => true
																		 , nid => B64NID
																		 , sid => SID
																		 , uid => UID}),

					{ok, #{
						  port => Ref
						, path => Path
						, rest => <<>>
						, nid => B64NID
						, sid => SID
						, uid => UID
						, conn => Conn
					}}
			end;

      {error, {exit, {signal, 11}}} ->
         {error, eaccess};


      {error, {_, Err}} when is_list(Err) ->
         {error, Err};

      {error, _} = Err ->
         Err
   end.

handle_call(steal, _from, #{port := Port} = State) ->
   {reply, {ok, Port}, State};

handle_call({send, Buf}, _From, #{port := Port} = State) ->
   io:format("uart/send: ~p~n", [Buf]),
   Reply = gen_serial:bsend(Port, [Buf], 1000),
   {reply, Reply, State};

handle_call(stop, _From, #{port := Port} = State) ->
   ok = gen_serial:close(Port, 1000),
   {stop, normal, ok, State}.

handle_cast(nil, State) -> {noreply, State}.

handle_info({serial, Port, Buf}, #{port := Port, rest := Rest} = State) ->
   NewBuf = <<Rest/binary, Buf/binary>>,
   case find_pkt(NewBuf) of
      {ok, {Packet, NewRest}} ->
         io:format("uart/recv: ~p~n", [Packet]),
         #{nid := NID} = State,

         ok = maybe_ship(NID, Packet),

         {noreply, State#{rest => NewRest}};

      {continue, NewRest} ->
         {noreply, State#{rest => NewRest}}
   end;

handle_info({bus, {_PID, _NID, upstream}, Buf}, #{port := Port} = State) ->
   ok = gen_serial:bsend(Port, [Buf], 1000),
   {noreply, State};

handle_info({bus, {_PID, _NID, upstream}, _Buf}, #{} = State) ->
   {noreply, State};

handle_info({bus, {_PID, _NID, downstream}, _Buf}, State) -> {noreply, State}.


terminate(_Reason, #{port := Port, path := Path, conn := Conn}) ->
  	_ = gen_serial:close(Port, 1000),
   ok = tinyconnect_tty_ports:update(Path, #{uart => false}),
	ok = gen_server:call(Conn, stop).

code_change(_OldVsn, _NewVsn, State) -> {ok, State}.

find_pkt(<<">">>) -> {ok, {<<">">>, <<>>}};
find_pkt(<<Len, _SID:32, _UID:32, _:56, N, _Rest/binary>> = Buf)
      when byte_size(Buf) >= Len, (N =:= 16 orelse N =:= 2) ->

   <<Packet:(Len)/binary, Rest/binary>> = Buf,
   {ok, {Packet, Rest}};

find_pkt(<<Len, _/binary>> = Buf) when byte_size(Buf) =< Len -> {continue, Buf};
find_pkt(<<Len, Rest/binary>> = Buf) when byte_size(Buf) =< Len -> {continue, Rest}.

maybe_create_pg2_group(Group) ->
   case pg2:join(Group, self()) of
      {error, {no_such_group, Group}} ->
         ok = pg2:create(Group),
         pg2:join(Group, self());

      ok ->
         ok
   end.

maybe_ship(NID, Buf) ->
   case pg2:get_members(NID) of
      {error, {no_such_group, _}} ->
         ok;

      Items ->
         lists:foreach(fun(PID) -> PID ! {bus, {self(), NID, downstream}, Buf} end, Items)
   end.

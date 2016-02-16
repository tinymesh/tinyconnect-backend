-module(tinyconnect_http).

-export([
     init/0
   , handle/3
]).

init() ->
   sockjs_handler:init_state(<<"/sockjs">>, fun handle_init/3, #{}, []).

handle_init(Conn, Ev, State) ->
   io:format("sockjs: ev: ~p~n", [Ev]),
   ?MODULE:handle(Conn, Ev, State).

handle(Conn, init, State) ->
   io:format("sockjs: init~n"),

   spawn_link(fun() ->
      ok = pg2:join(ports, self()),

      loop(Conn)
   end),

   {ok, State};

handle(_Conn, closed, State) ->
   io:format("sockjs: closed~n"),
   {stop, State};

handle(Conn, {recv, Ev}, State) ->
   case 'Elixir.Poison':decode(Ev) of
      {ok, #{<<"ev">> := _Ev} = Req} ->
         {ok, _NewState} = handle_req(Conn, Req, State);

      {error, Err} ->
         send(#{error => Err}, Conn),
         {ok, State}
   end;

handle(_Conn, {info, {'EXIT', _, normal}}, State) ->
   {ok, State}.

loop(Conn) ->
   receive
      {ports, NewPorts} ->
         send(#{ev => <<"uart-list">>, data => NewPorts}, Conn),
			loop(Conn)
   end.

send(#{<<"ev">> := Ev} = Req, Conn) ->
   Buf = 'Elixir.Poison':'encode!'(Req),
   io:format("sockjs: send[~p] -> ~p~n", [self(), Ev]),
   sockjs:send(Buf, Conn);
send(#{ev := Ev} = Req, Conn) ->
   Buf = 'Elixir.Poison':'encode!'(Req),
   io:format("sockjs: send[~p] -> ~p~n", [self(), Ev]),
   sockjs:send(Buf, Conn).

handle_req(Conn, #{<<"ev">> := <<"uart-list">>}, State) ->
   {ok, Ports} = tinyconnect_tty_ports:get(),
   Resp = #{
        ev   => <<"uart-list">>
      , data => Ports
   },

   ok = send(Resp, Conn),

   {ok, State};

handle_req(Conn, #{<<"ev">> := <<"disconnect-device">>, <<"data">> := #{<<"id">> := Port}} = Req, State) ->
   #{<<"ref">> := Ref} = Req,

   case tinyconnect_tty_ports:get(Port) of
      {ok, #{path := Path}} ->
         ok = tinyconnect_tty_sup:stop_port(Path),
         {ok, State};

      nil ->
         Resp = #{<<"ref">>    => Ref,
                  <<"ev">>     => <<"disconnect-device">>,
                  <<"status">> => <<"not-found">>},
         ok = send(Resp, Conn),

         {ok, State}
   end;

handle_req(Conn, #{<<"ev">> := <<"connect-device">>, <<"data">> := #{<<"id">> := Port}} = Req, State) ->
   #{<<"ref">> := Ref} = Req,

   case tinyconnect_tty_ports:get(Port) of
      {ok, #{path := Path}} ->
         case tinyconnect_tty_sup:start_port(Path) of
            {ok, _} ->
               Resp = #{<<"ref">>    => Ref,
                        <<"ev">>     => <<"connect-device">>,
                        <<"status">> => <<"ok">>},
               ok = send(Resp, Conn);

            {error, Err} when is_atom(Err); is_list(Err); is_binary(Err) ->
               Err2 = case Err of
                  Err when is_list(Err) -> iolist_to_binary(Err);
                  Err -> Err
               end,

               Resp = #{<<"ref">>    => Ref,
                        <<"ev">>     => <<"connect-device">>,
                        <<"status">> => <<"error">>,
                        <<"error">>  => Err2},
               ok = send(Resp, Conn)
         end,

         {ok, State};

      nil ->
         Resp = #{<<"ref">>    => Ref,
                  <<"ev">>     => <<"connect-device">>,
                  <<"status">> => <<"not-found">>},
         ok = send(Resp, Conn),

         {ok, State}
   end;

handle_req(Conn, #{<<"ev">> := <<"subscribe">>,
						 <<"data">> := #{<<"id">> := PortID}} = Req, State) ->

   #{<<"ref">> := Ref} = Req,

	spawn_monitor(fun() ->
		receive X -> io:format("diiieeee? ~p~n", [X]) end
	end),

   case tinyconnect_tty_ports:get(PortID) of
      {ok, #{nid := NID}} ->
			PortID2 = binary_to_atom(PortID, utf8),

			{Parent, RetRef} = {self(), make_ref()},
			{Child, MonRef} = spawn_monitor(fun() ->
				true = link(Parent),
				_ = pg2:create(<<"port:", PortID/binary>>),
				ok = pg2:join(<<"port:", PortID/binary>>, self()),

				case NID of
					nil -> ok;
					NID ->
						_ = pg2:create(NID),
						ok = pg2:join(NID, self())
				end,

				Parent ! {RetRef, ok},

				loop_data(Conn, PortID2, NID)
			end),

			receive
				{RetRef, ok} ->
					Resp = #{<<"ref">>    => Ref,
								<<"ev">>     => <<"subscribe">>,
								<<"status">> => <<"ok">>},

					true = link(Child),
					ok = send(Resp, Conn),
					{ok, State};

				{'DOWN', MonRef, process, Child, _} ->
					Resp = #{<<"ref">>    => Ref,
								<<"ev">>     => <<"subscribe">>,
								<<"status">> => <<"error">>},

					ok = send(Resp, Conn),
         		{ok, State}
			end;

      {error, notfound} ->
         Resp = #{<<"ref">>    => Ref,
                  <<"ev">>     => <<"subscribe">>,
                  <<"status">> => <<"not-found">>},
         ok = send(Resp, Conn),

         {ok, State}
   end.

loop_data(Conn, PortID, NID) ->
	receive
		{bus, {_PID, {PortID, NewNID}, Chan}, Buf} when NID =:= nil->
			_ = pg2:create(NewNID),
			ok = pg2:join(NewNID, self()),

			io:format("data[~p] -> ~p -> ~p~n", [NID, Chan, Buf]),

			send(#{
				ev => <<"data">>,
				data => base64:encode(Buf),
				port => PortID,
				channel => Chan,
				timestamp => millis()
			}, Conn),

			loop_data(Conn, PortID, NewNID);

		{bus, {_PID, {MatchPortID, MatchNID}, Chan}, Buf} when PortID =:= MatchPortID; NID =:= MatchNID ->
			io:format("data[~p] -> ~p -> ~p~n", [NID, Chan, Buf]),
			send(#{
				ev => <<"data">>,
				data => base64:encode(Buf),
				port => PortID,
				channel => Chan,
				timestamp => millis()
			}, Conn),

			loop_data(Conn, PortID, NID);

		X ->
			io:format("got random ev[~p]: ~p~n", [NID, X]),
			loop_data(Conn, PortID, NID)
	end.

millis() -> erlang:system_time() div 1000000.

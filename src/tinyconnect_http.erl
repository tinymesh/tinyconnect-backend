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
   {ok, State};

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

send(Req, Conn) ->
   Buf = 'Elixir.Poison':'encode!'(Req),
   io:format("sockjs: send[~p] -> ~p~n", [self(), Req]),
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
						 <<"data">> := #{<<"id">> := Port}} = Req, State) ->

   #{<<"ref">> := Ref} = Req,

   case tinyconnect_tty_ports:get(Port) of
      {ok, #{nid := NID}} ->
			Resp = #{<<"ref">>    => Ref,
						<<"ev">>     => <<"subscribe">>,
						<<"status">> => <<"ok">>},

			ok = send(Resp, Conn),

			spawn(fun() ->
				_ = pg2:create(NID),
				ok = pg2:join(NID, self()),
				loop_data(Conn, Port, NID)
			end),

         {ok, State};

      {error, notfound} ->
         Resp = #{<<"ref">>    => Ref,
                  <<"ev">>     => <<"subscribe">>,
                  <<"status">> => <<"not-found">>},
         ok = send(Resp, Conn),

         {ok, State}
   end.

loop_data(Conn, Port, NID) ->
	receive
		{bus, {_PID, NID, Chan}, Buf} ->
			io:format("data[~p] -> ~p -> ~p~n", [NID, Chan, Buf]),
			send(#{
				ev => <<"data">>,
				data => base64:encode(Buf),
				port => Port,
				channel => Chan,
				timestamp => millis()
			}, Conn),

			loop_data(Conn, Port, NID);

		X ->
			io:format("got random ev[~p]: ~p~n", [NID, X]),
			loop_data(Conn, Port, NID)
	end.

millis() -> erlang:system_time() div 1000000.

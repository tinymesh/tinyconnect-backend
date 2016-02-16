-module(tinyconnect_config).

% Helper functions to ensure the configuration of a module

-export([
     identify/1
   , ensure/2
]).

identify(Port) -> identify(Port, <<>>, 6).

identify(_Port, _Acc, 0) -> {error, timeout};
identify(Port, Acc, N) ->
   ok = gen_serial:bsend(Port, <<10, 0, 0, 0, 0, 0, 3, 16, 0, 0>>, 1000),
	case collect(Port, Acc) of
		{ok, {Packet, Rest}} ->
			case Packet of
				<<35, SID:32, UID:32, _:56, 2, 18, _:16, NID:32, _/binary>> ->
					gen_serial:bsend(Port, <<6>>, 1000),
					{ok, {NID, SID, UID}};

				_ ->
					gen_serial:bsend(Port, <<6>>, 1000),
					identify(Port, Rest, N - 1)
			end;

		{error, timeout} ->
			gen_serial:bsend(Port, <<6>>, 1000),
			identify(Port, <<>>, N - 1)
	end.


collect(Port, Acc) ->
   receive
      {serial, Port, Buf} ->
         case find_pkt(<<Acc/binary, Buf/binary>>) of
            {ok, {Packet, Rest}} ->
               {ok, {Packet, Rest}};

            {continue, Rest} ->
               collect(Port, Rest)
         end
   after 100 ->
      {error, timeout}
   end.

find_pkt(<<">">>) -> {ok, {<<">">>, <<>>}};
find_pkt(<<Len, _SID:32, _UID:32, _:56, N, _Rest/binary>> = Buf)
      when byte_size(Buf) >= Len, (N =:= 16 orelse N =:= 2) ->

   <<Packet:(Len)/binary, Rest/binary>> = Buf,
   {ok, {Packet, Rest}};

find_pkt(<<Len, _/binary>> = Buf) when byte_size(Buf) =< Len -> {continue, Buf};
find_pkt(<<Len, Rest/binary>> = Buf) when byte_size(Buf) =< Len -> {continue, Rest};
find_pkt(_Buf) -> {continue, <<>>}.



ensure(_Port, #{nid := NID, sid := SID, uid := UID} = Config) ->
   % Ask for config
   %FD ! {send, <<10,0,0,0,0,0,3,16,0,0>>},

   case collect_data(nil) of
      <<35, DevSID:32, DevUID:32, _:56, 2, 18, _:16, DevNID:32, _/binary>>
         when DevNID =:= NID, DevSID =:= SID, DevUID =:= UID ->
         ok;

      <<35, _DevSID:32, DevUID:32, _:56, 2, 18, _:16, _DevNID:32, _/binary>> ->
         nil ! {send, <<10, DevUID:32, 1, 3, 33, 0, 0>>},
         ensure2(Config, true);

      <<">">> ->
         ensure2(Config, false);

      <<>> ->
         ensure2(Config, true)
   end.

collect_data(FD) -> collect_data(FD, []).
collect_data(FD, Acc) ->
   receive
      {data, Buf} -> collect_data(FD, [Buf | Acc])
   after
      100 -> iolist_to_binary(lists:reverse(Acc))
   end.


ensure2(#{} = Config, true) ->
   ok = wait_for_config_mode(Config),
   ensure2(Config, false);
ensure2(#{fd := FD} = Config, false) ->
   ok = ensure3([gateway, nid, sid, uid], Config),
   FD ! {send, <<"X">>}.

ensure3([gateway | Rest], #{fd := FD} = Config) ->
   FD ! {send, <<"G">>},
   ok = wait_for_config_prompt(),

   FD ! {send, <<"M">>},
   ok = wait_for_config_prompt(),

   FD ! {send, <<3, 0, 255>>},
   ok = wait_for_config_prompt(),

   ensure3(Rest, Config);
ensure3([nid | Rest], #{fd := FD, nid := NID} = Config) ->
   <<N1, N2, N3, N4>> = <<NID:32>>,

   FD ! {send, <<"HW">>},
   ok = wait_for_config_prompt(),

   FD ! {send, <<23, N1, 24, N2, 25, N3, 26, N4, 255>>},
   ok = wait_for_config_prompt(),

   ensure3(Rest, Config);
ensure3([sid | Rest], #{fd := FD, sid := SID} = Config) ->
   <<S1, S2, S3, S4>> = <<SID:32>>,

   FD ! {send, <<"M">>},
   ok = wait_for_config_prompt(),

   FD ! {send, <<49, S1, 50, S2, 51, S3, 52, S4, 255>>},
   ok = wait_for_config_prompt(),

   ensure3(Rest, Config);
ensure3([uid | Rest], #{fd := FD, uid := UID} = Config) ->
   <<U1, U2, U3, U4>> = <<UID:32>>,

   FD ! {send, <<"M">>},
   ok = wait_for_config_prompt(),

   FD ! {send, <<45, U1, 46, U2, 47, U3, 48, U4, 255>>},
   ok = wait_for_config_prompt(),

   ensure3(Rest, Config);
ensure3([], _Config) -> ok.

wait_for_config_mode(#{fd := FD} = Config) ->
   % 0 bytes are mostly harmless, either returns prompt OR nothing
   FD ! {send, <<0>>},
   receive
      {data, <<">">>} -> ok;
      {date, _} -> wait_for_config_mode(Config)
   after
      2500 -> {error, timeout}
   end.

wait_for_config_prompt() ->
   receive
      {data, <<">">>} -> ok
   after
      2500 -> {error, timeout}
   end.

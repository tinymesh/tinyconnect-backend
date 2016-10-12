-module(tinyconnect_plugins).

-export([
     protostate/2
   , deframe/2
   , filter/2
]).

% Determine state of tinymesh serial link and emits data only if certain state is active
-define(protostates, [config, unknown, proto]).

protostate({start, _, #{<<"emit">> := Emits}}, _) ->
   Emits2 = lists:map(fun(<<"config">>) -> config;
                         (<<"proto">>) -> proto;
                         (<<"unknown">>) -> unknown end, Emits),
   {state, {unknown, Emits2, <<>>}};
protostate({start, _, _}, _) -> {state, {unknown, [proto, unknown], <<>>}};
protostate({event, input, Buf = <<">">>, _Meta}, {_OldState, Allowed, _}) ->
   %io:format("protostate changed from ~p -> config~n", [OldState]),
   maybe_emit(Buf, {config, Allowed, <<>>});
% transition from config -> protocol
protostate({event, input, <<Buf/binary>>, _Meta}, {OldState, Allowed, Rest}) when OldState =/= proto ->
   Input = <<Rest/binary, Buf/binary>>,
   End = binary:part(Input, max(byte_size(Input) - 35, 0), min(35, byte_size(Input))),

   case End of
      <<35, _:120, 2, _Detail, _:136>> ->
         %io:format("protostate changed from ~p -> protocol~n", [OldState]),
         maybe_emit(End, {proto, Allowed, <<>>});

      _ ->
         maybe_emit(Buf, {OldState, Allowed, End})
   end;
protostate({event, input, <<Buf/binary>>, _Meta}, {ProtoState, Allowed, Rest}) ->
   Input = <<Rest/binary, Buf/binary>>,
   End = binary:part(Input, max(byte_size(Input) - 35, 0), min(35, byte_size(Input))),
   maybe_emit(Buf, {ProtoState, Allowed, End}).

maybe_emit(Buf, {ProtoState, Allowed, _Rest} = State) ->
   case lists:member(ProtoState, Allowed) of
      true -> {emit, input, Buf, State};
      false-> {state, State}
   end.


% stateful packet deframing
%
% deframe emits a single packet at a time
deframe({start, _, _}, _) -> {state, []};
deframe({event, input, <<Buf/binary>>, _Meta}, State) ->
   Input = [{erlang:timestamp(), Buf} | State],
   case {Buf, deframe2(Input)} of
      % the thing is in config mode, reset state as it's useless now
      {<<">">>, false} ->
         {state, []};

      {_, {ok, {_When, Frame}, NewState}} ->
         {emit, data, Frame, NewState};

      {_, false} ->
         {state, Input}
   end.

deframe2(Input) -> deframe2(lists:reverse(Input), {undefined, undefined, <<>>}).

deframe2([{_, <<Len, _/binary>>} | Rest], {undefined, undefined, <<>>} = Acc)
   when Len > 138; (Len < 18 andalso Len =/= 10) ->
   deframe2(Rest, Acc);

deframe2([{When, Buf} | Rest], {undefined, undefined, <<>>}) ->
   deframe2(Rest, {When, When, Buf});

deframe2(Fragments, {When, Last, <<Len, _/binary>> = Acc})
   when byte_size(Acc) >= Len ->

   case Acc of
      <<Buf:(Len)/binary>> ->
         {ok, {When, Buf}, lists:reverse(Fragments)};

      <<Buf:(Len)/binary, Next/binary>> ->
         {ok, {When, Buf}, lists:reverse([{Last, Next} | Fragments])}
   end;

deframe2([{Last, Buf} | Rest], {When, _Last, Acc}) ->
   deframe2(Rest, {When, Last, <<Acc/binary, Buf/binary>>});

deframe2([], _Acc) -> false.




% given a collection filter based on simple (non)equality:
% filter [<<"a != b">>, <<"b > 0">>]
filter({start, _, _}, _) -> {state, nil}.

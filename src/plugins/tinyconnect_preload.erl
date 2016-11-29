-module(tinyconnect_preload).

-export([
   deframe/2
]).

% Deframe Tinymesh events from a serial port
deframe({start, _, _}, _) -> {ok, #{mode => unknown, data => []}};
deframe({event, input, <<Buf/binary>>, _Meta}, #{data := Data} = State) ->
   Input = [{erlang:timestamp(), Buf} | Data],
   case {Buf, deframe2(Input)} of
      % the thing is in config mode, reset state as it's useless now
      {<<">">>, false} ->
         {state, State#{mode => config, data => []}};

      {_, {ok, {_When, Frame}, Fragments}} ->
         {emit, data, Frame, State#{data => Fragments, mode => protocol}};

      {_, drop} ->
         {state, State#{data => []}};

      {_, false} ->
         {state, State#{data => Input}}
   end.

deframe2(Input) -> deframe2(lists:reverse(Input), {undefined, undefined, <<>>}).

% this one is obviously all wrong, skip fragment
deframe2([{_, <<Len, _/binary>>} | Rest], {undefined, undefined, <<>>} = Acc)
   when Len > 138; (Len < 18 andalso Len =/= 10) ->
   deframe2(Rest, Acc);

% start of new frame
deframe2([{When, Buf} | Rest], {undefined, undefined, <<>>}) ->
   deframe2(Rest, {When, When, Buf});

% aggregate data until Length and type matches matches
deframe2(Fragments, {When, Last, <<Len, _/binary>> = Acc})
   when byte_size(Acc) >= Len ->

   case Acc of
      <<_Len:8, _Header:120, Type, _Rest>> when Type =/= 2 andalso Type =/= 16 ->
         drop;

      <<Buf:(Len)/binary>> ->
         {ok, {When, Buf}, lists:reverse(Fragments)};

      <<Buf:(Len)/binary, Next/binary>> ->
         {ok, {When, Buf}, lists:reverse([{Last, Next} | Fragments])}
   end;

deframe2([{Last, Buf} | Rest], {When, _Last, Acc}) ->
   deframe2(Rest, {When, Last, <<Acc/binary, Buf/binary>>});

deframe2([], _Acc) -> false.



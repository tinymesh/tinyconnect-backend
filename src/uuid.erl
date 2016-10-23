-module(uuid).

-export([uuid/0, uuid/1]).

-type uuid() :: binary().

-spec uuid() -> uuid().
uuid() -> uuid(erlang:timestamp()).

-spec uuid(erlang:timestamp()) -> uuid().
uuid({Hi, Mid, Low}) ->
   <<Seq:14>> = clockseq(),
   iolist_to_binary(string:to_lower(
      [ integer_to_list(Hi, 32)
      , $-
      , integer_to_list(Mid, 32)
      , $-
      , integer_to_list(Low, 32)
      , $-
      , integer_to_list(Seq, 32)])).

clockseq() ->
   Pid = erlang:phash2(self()),
   <<N0:32, N1:32, N2:32>> = crypto:rand_bytes(12),
   _ = random:seed({N0 bxor Pid, N1 bxor Pid, N2 bxor Pid}),
   <<(random:uniform(2 bsl 14 - 1)):14>>.

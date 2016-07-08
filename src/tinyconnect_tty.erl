-module(tinyconnect_tty).
-behaviour(gen_server).

% Server for working with a communication port

-export([
     start/2, start/3, start/4
   , start_link/2 , start_link/3, start_link/4

   , send/2

   , stop/0
   , stop/1

   , init/1
   , handle_call/3
   , handle_cast/2
   , handle_info/2
   , terminate/2
   , code_change/3
]).

start(Path, Callback) -> start(Path, Callback, []).
start(<<Path/binary>>, Callback, Opts) -> start(Path, Callback, Opts, <<>>).
start(<<Path/binary>>, Callback, undefined, Initial) -> start(Path, Callback, [], Initial);
start(<<Path/binary>>, Callback, Opts, Initial) when is_function(Callback) ->
   gen_server:start(?MODULE, [self(), Path, Callback, Opts, Initial], []).


start_link(Path, Callback) -> start_link(Path, Callback, []).
start_link(<<Path/binary>>, Callback, Opts) -> start_link(Path, Callback, Opts, <<>>).
start_link(<<Path/binary>>, Callback, undefined, Initial) -> start_link(Path, Callback, [], Initial);
start_link(<<Path/binary>>, Callback, Opts, Initial) when is_function(Callback) ->
   gen_server:start_link(?MODULE, [self(), Path, Callback, Opts, Initial], []).

send(Buf, Server) ->
   gen_server:call(Server, {send, Buf}).

stop()       -> stop(?MODULE).
stop(Server) -> gen_server:call(Server, stop).

init([Caller, Path, Callback, ConnOpts, Initial]) ->
   Path2 = binary_to_list(Path),
   PortID = binary_to_atom(filename:basename(Path), utf8),

   Opts = orddict:merge(fun(_, _A, B) -> B end,
                        orddict:from_list([{active, once}, {packet, none}, {baud, 19200}, {flow_control, none}]),
                        orddict:from_list(ConnOpts)),

   case gen_serial:open(Path2, Opts) of
      {ok, Port} ->
         Caller ! {self(), open},

         {ok, #{
              port => Port
            , id => PortID
            , path => Path
            , rest => Initial
            , callback => Callback
            , tinymesh => {_NID = nil, _SID = nil, _UID = nil}}};

      {error, {exit, {signal, 11}}} ->
         {error, eaccess};


      {error, {_, Err}} when is_list(Err) ->
         {error, Err};

      {error, _} = Err ->
         Err
   end.

handle_call({send, Buf}, _From, #{port := Port} = State) ->
   Reply = gen_serial:bsend(Port, [Buf], 1000),
   {reply, Reply, State};

handle_call(stop, _From, #{port := Port} = State) ->
   ok = gen_serial:close(Port, 1000),
   {stop, normal, ok, State}.

handle_cast(nil, State) -> {noreply, State}.

handle_info({serial, Port, Buf}, #{port := Port, rest := Rest, callback := Callback} = State) ->
   case Callback(Port, Buf, Rest) of
      {continue, NewRest} ->
         {noreply, State#{rest => NewRest}};

      {next, NewRest, Next} ->
         {noreply, State#{rest => NewRest, callback => Next}};

      {halt, Reason} ->
         {stop, Reason, State}
   end.

terminate(_Reason, #{port := Port}) ->
   _ = gen_serial:close(Port, 1000),
   ok.

code_change(_OldVsn, _NewVsn, State) -> {ok, State}.
%
%find_pkt(<<">">>) -> {ok, {<<">">>, <<>>}};
%find_pkt(<<Len, _SID:32, _UID:32, _:56, N, _Rest/binary>> = Buf)
%      when byte_size(Buf) >= Len, (N =:= 16 orelse N =:= 2) ->
%
%   <<Packet:(Len)/binary, Rest/binary>> = Buf,
%   {ok, {Packet, Rest}};
%
%find_pkt(<<Len, _/binary>> = Buf) when byte_size(Buf) =< Len -> {continue, Buf};
%find_pkt(<<Len, Rest/binary>> = Buf) when byte_size(Buf) =< Len -> {continue, Rest}.

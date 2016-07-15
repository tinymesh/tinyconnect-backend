-module(tinyconnect_tty).
-behaviour(gen_server).

% manages UART connections by creating the connection to the different
% serial ports, then identifying them (if get_nid is used).

-export([
     send/2

   , if_packet/2

   , name/1
   , stop/1

   , start_link/2
   , init/1
   , handle_call/3
   , handle_cast/2
   , handle_info/2
   , terminate/2
   , code_change/3
]).

-export_type([def/0]).

-type channel() :: tinyconnect_channel:channel().
-type def() :: #{
   port => {id, ID :: atom()} | {path, Path :: file:filename_all()},
   portopts => gen_serial:option_list(),
   % what sources to subscribe to events from
   subscribe => [channel() | {channel(), [PlugName :: binary()]}],
   % the module to handle tty connections
   % name of plugin
   name => Name :: binary(),
   % opts for gen_server
   opts => Opts :: term(),
   start_after => [],
   backoff => {TimerRef :: reference() | undefined, undefined | backoff:backoff()},

   portref     => undefined | port(),
   identity    => {NID :: undefined, SID :: undefined, UID :: undefined},
   rest        => binary(),
   mode        => unknown | protocol | config,
   handshake   => software | hardware | wait_for_ack
}.

default(Chan) ->
   #{
      port        => undefined,
      portopts    => [],
      autoconnect => false,
      subscribe   => [{Chan, ["cloudsync"]}],
      portref     => undefined,
      identity    => {_NID = undefined, _SID = undefined, _UID = undefined},
      rest        => [],
      mode        => unknown,
      handshake   => wait_for_ack
    }.

-spec send(pid(), iolist()) -> ok.
send(Server, Buf) ->
   gen_server:call(Server, {send, Buf}).

if_packet(_Resource, #{type := T}) -> packet =:= T.

%% plugin api

-spec name(pid()) -> {ok, Name :: binary()}.
name(Server) -> gen_server:call(Server, name).

-spec stop(pid()) -> ok.
stop(Server) -> gen_server:call(Server, stop).


%%%% gen_server implementation
%%%
-spec start_link(Chan :: channel(), def()) -> {ok, pid()} | {error, term()}.
start_link(Chan, PluginDef) ->
   Plugin = maps:merge(default(Chan), PluginDef),
   gen_server:start_link(?MODULE, [Chan, Plugin], []).

init([Chan, #{name := Name,
              port := {path, Port},
              portopts := PortOpts,
              channel := Chan} = Plugin]) ->

   ok = tinyconnect_channel:subscribe([Chan, Name], Plugin),

   Opts = orddict:merge(fun(_, _A, B) -> B end,
                        orddict:from_list([{active, true}, {packet, none}, {baud, 19200}, {flow_control, none}]),
                        orddict:from_list(PortOpts)),

   case gen_serial:open(Port, Opts) of
      {ok, PortRef} ->
         tinyconnect_channel:emit([Chan, Name], Plugin, open, #{pid => self()}),

         % send a single byte, in config mode this will prompt back
         ok = gen_serial:bsend(PortRef, <<0>>, 100),

         Mode = receive
            {serial, PortRef, <<">">>} -> config
         after 100 ->
            ok = gen_serial:bsend(PortRef, <<10, 0:32, 0, 3, 16, 0:16>>, 100),
            unknown
         end,

         {ok, Plugin#{
            portref => PortRef,
            rest    => [],
            mode    => Mode
         }};

      {error, {exit, {signal, 11}}} ->
         {error, eaccess};


      {error, {_, Err}} when is_list(Err) ->
         {error, Err};

      {error, _} = Err ->
         Err
   end;
init([_Chan, #{} = Plugin]) ->
   case {maps:get(name, Plugin, nil),
         maps:get(channel, Plugin, nil),
         maps:get(port, Plugin, nil),
         maps:get(portopts, Plugin, nil)} of
      {nil, _, _, _} -> {stop, {error, {argument, name}}};
      {_, nil, _, _} -> {stop, {error, {argument, channel}}};
      {_, _, nil, _} -> {stop, {error, {argument, port}}};
      {_, _, _, nil} -> {stop, {error, {argument, portopts}}};
      {_, _, P, _} when P =/= nil -> {stop, {error, {argument, port}}}
   end.


handle_call(stop, _From, State) -> {stop, normal, ok, State};
handle_call(name, _From, #{name := Name} = State) -> {reply, {ok, Name}, State};
handle_call({send, Buf}, _From, #{portref := Port} = State) ->
   Reply = gen_serial:bsend(Port, [Buf], 1000),
   {reply, Reply, State}.

handle_cast(nil, State) -> {noreply, State}.
handle_info({serial, Port, Buf},
            #{portref := Port, rest := Rest, mode := Mode} = State) ->

   #{channel := Chan, name := Name} = State,
   Input = [{erlang:timestamp(), Buf} | Rest],

   case {Mode, Buf, deframe(Input)} of
      {protocol, _, {ok, {When, Frame}, NewRest}} ->
         % regular serial data for everyone
         DEv = #{data => Buf, mode => protocol},
         ok = tinyconnect_channel:emit([Chan, Name], State, data, DEv),

         % and highlevel packet events for those other ones
         PEv = #{data => Frame, at => When, mode => protocol},
         ok = tinyconnect_channel:emit([Chan, Name], State, packet, PEv),

         ok = maybe_ack(State),
         {noreply, State#{rest => NewRest}};

      % set in config mode, reset input for each prompt received
      {Mode, <<">">> = Buf, false} ->
         Ev = #{data => Buf, mode => config},
         ok = tinyconnect_channel:emit([Chan, Name], State, data, Ev),
         {noreply, State#{mode => config, rest => []}};

      % Escape from config or unknown mode by reset/get_nid event
      {_, _, {ok, {When, Frame}, NewRest}} ->
         PEv = #{data => Frame, at => When, mode => protocol},
         ok = tinyconnect_channel:emit([Chan, Name], State, packet, PEv),

         DEv = #{data => Buf, at => When, mode => protocol},
         ok = tinyconnect_channel:emit([Chan, Name], State, data, DEv),

         ok = maybe_ack(State),
         case Frame of
            <<35, SID:32, UID:32, _Header:7/binary, 2, 18, _:16, NIDIn:32, _:11/binary>> ->
               NID = integer_to_binary(NIDIn, 36),
               {noreply, State#{mode => protocol,
                                rest => NewRest,
                                identity => {NID, SID, UID}}};

            <<_/binary>> ->
               {noreply, State#{mode => protocol, rest => NewRest}}
         end;

      {_, Buf, false} ->
         Ev = #{data => Buf, mode => Mode},
         ok = tinyconnect_channel:emit([Chan, Name], State, data, Ev),
         {noreply, State#{mode => config, rest => Input}}
   end;
handle_info({serial_closed, Port}, #{portref := Port} = State) ->
   {stop, {serial, closed}, State};

handle_info({'$tinyconnect', _Res, #{data := Buf} = _Ev}, #{portref := Port} = State) ->
   ok = gen_serial:bsend(Port, Buf, 1000),
   {noreply, State};
handle_info({'$tinyconnect', _Res, #{}}, #{} = State) ->
   {noreply, State}.

maybe_ack(#{handshake := wait_for_ack, portref := Port}) ->
   gen_serial:bsend(Port, <<6>>, 1000),
   ok;
maybe_ack(_) -> ok.

terminate(_Reason, #{portref := Port}) ->
   _ = gen_serial:close(Port, 1000),
   ok.

code_change(_OldVsn, _NewVsn, State) -> {ok, State}.

deframe(Input) ->
   deframe(lists:reverse(Input), {undefined, undefined, <<>>}).

deframe([{_, <<Len, _/binary>>} | Rest], {undefined, undefined, <<>>} = Acc)
   when Len > 138; (Len < 18 andalso Len =/= 10) ->

   deframe(Rest, Acc);

deframe([{When, Buf} | Rest], {undefined, undefined, <<>>}) ->
   deframe(Rest, {When, When, Buf});

deframe(Fragments, {When, Last, <<Len, _/binary>> = Acc})
   when byte_size(Acc) >= Len ->

   case Acc of
      <<Buf:(Len)/binary>> ->
         {ok, {When, Buf}, lists:reverse(Fragments)};

      <<Buf:(Len)/binary, Next/binary>> ->
         {ok, {When, Buf}, lists:reverse([{Last, Next} | Fragments])}
   end;

deframe([{Last, Buf} | Rest], {When, _Last, Acc}) ->
   deframe(Rest, {When, Last, <<Acc/binary, Buf/binary>>});

deframe([], _Acc) -> false.

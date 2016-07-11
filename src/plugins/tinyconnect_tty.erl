-module(tinyconnect_tty).
-behaviour(gen_server).

% manages UART connections by creating the connection to the different
% serial ports, then identifying them (if get_nid is used).

-export([
     send/2

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
                        orddict:from_list([{active, false}, {packet, none}, {baud, 19200}, {flow_control, none}]),
                        orddict:from_list(PortOpts)),

   case gen_serial:open(Port, Opts) of
      {ok, PortRef} ->
         tinyconnect_channel:emit([Chan, Name], Plugin, open, #{pid => self()}),

         % send a single byte, in config mode this will prompt back
         ok = gen_serial:bsend(PortRef, <<0>>, 100),

         {ok, Plugin#{
            portref => PortRef,
            rest    => [],
            mode    => unknown
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
         Ev = #{data => Frame, at => When, mode => protocol},
         tinyconnect_channel:emit([Chan, Name], State, data, Ev),
         ok = maybe_ack(State),
         {noreply, State#{rest => NewRest}};

      % set in config mode, reset input for each prompt received
      {Mode, <<">">> = Buf, false} ->
         Ev = #{data => Buf, mode => config},
         tinyconnect_channel:emit([Chan, Name], State, data, Ev),
         {noreply, State#{mode => config, rest => []}};

      % Escape from config or unknown mode by reset/get_nid event
      {_, _, {ok, {When, Frame}, NewRest}} ->
         Ev = #{data => Frame, at => When, mode => protocol},
         tinyconnect_channel:emit([Chan, Name], State, data, Ev),
         ok = maybe_ack(State),
         case Frame of
            <<35, SID:32, UID:32, _Header:7/binary, 2, 18, _:16, NIDIn:32, _:11/binary>> ->
               NID = integer_to_binary(NIDIn, 36),
               {noreply, State#{mode => protocol,
                                rest => NewRest,
                                identity => {NID, SID, UID}}};

            <<35, _Header:11/binary, 0:16, _Latency:16, 2, 8, _:17/binary>> ->
               {noreply, State#{mode => protocol, rest => NewRest}}
         end;

      % set in config mode
      {_, Buf, false} ->
         Ev = #{data => Buf, mode => Mode},
         tinyconnect_channel:emit([Chan, Name], State, data, Ev),
         {noreply, State#{mode => config, rest => Input}}
   end.

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

%%
%%%% public members
%%
%%-spec identify(Server :: atom() | pid()) :: any().
%%identify(Server) ->
%%   gen_server:call(Server, {identify, Port}).
%%
%%%% handler abstract
%%-spec open(Server :: atom() | pid()) :: ok | {error, Err :: term().}
%%open(Server)  ->
%%   gen_server:call(Server, {open, NID}).
%%
%%-spec close(Server :: atom() | pid()) :: ok | {error, Err :: term().}
%%close(Server) ->
%%   gen_server:call(Server, {close, NID}).
%%
%%
%%%% gen_server implementation
%%
%%-spec start_link(RegName :: atom(), opts()) -> {ok, pid()} | {error, term()}.
%%start_link(Name) -> start_link(Name, []).
%%start_link(Name, Opts) ->
%%   gen_server:start_link({local, Name}, ?MODULE, [Name, Opts], []).
%%
%%init([Name, Opts]) ->
%%   process_flag(trap_exit, true),
%%
%%   ok = pg2:create(Name),
%%
%%
%%   Interval = application:get_env(tinyconnect, rescan_interval, 5000),
%%   timer:send_after(Interval, rescan),
%%
%%   ok = subscribe(lists:keyfind(subscribe, 1, Opts)),
%%
%%   File = application:get_env(tinyconnect, config_path, "/etc/tinyconnect.cfg"),
%%
%%   Info = case file:consult(File) of
%%      {ok, [Network|_]} -> Network;
%%      {ok, []} -> undefined end,
%%
%%   self() ! rescan,
%%
%%   {ok, #{
%%      ports => [],
%%      name => Name,
%%      workers => [],
%%      network => Info
%%   }}.
%%
%%subscribe(false) -> ok;
%%subscribe({subscribe, []}) -> ok;
%%subscribe({subscribe, [Group | Groups]}) ->
%%   ok = pg2:create(Group),
%%   ok = pg2:join(Group, self()),
%%   subscribe({subscribe, Groups}).
%%
%%
%%get_in_coll([], {_K, _V}) -> nil;
%%get_in_coll([#{} = H|T], {K, V}) ->
%%   case maps:get(K, H) of
%%      V -> V;
%%      _ -> get_in_coll(T, {K, V})
%%   end.
%%
%%
%%
%%uartchanges(OldPorts, Network) ->
%%   {ok, Ports} = listports(OldPorts),
%%
%%   % augment with network definition, if such exists
%%   NewPorts = case Network of
%%      #{serialport := PortID} ->
%%         lists:map(fun
%%            (#{id := ID} = Port) when PortID =:= ID -> maps:merge(Port, Network);
%%            (Port) -> Port
%%         end, Ports);
%%
%%      _ -> Ports end,
%%
%%   Added   = lists:filter( fun(#{id := ID}) -> nil =:= get_in_coll(OldPorts, {id, ID}) end, NewPorts),
%%   Removed = lists:filter( fun(#{id := ID}) -> nil =:= get_in_coll(NewPorts, {id, ID}) end, OldPorts),
%%
%%   {Added, Removed, NewPorts}.
%%
%%
%%
%%notify_changes({_,_} = Items, Group) -> notify_changes(Items, Group, []).
%%notify_changes({[], []}, Group, Acc) ->
%%   lists:foreach(fun(F) -> tinyconnect:emit(F, Group) end, Acc);
%%
%%notify_changes({[#{id := ID} | Rest], Removed}, Group, Acc) ->
%%   notify_changes({Rest, Removed}, Group, [{added, ID} | Acc]);
%%
%%notify_changes({[], [#{id := ID} | Rest]}, Group, Acc) ->
%%   notify_changes({[], Rest}, Group, [{removed, ID} | Acc]).
%%
%%
%%close_conns([], Workers) -> Workers;
%%close_conns([#{id := ID, mod := Mod} | Rest], Workers) ->
%%   case lists:keyfind(ID, 1, Workers) of
%%      {ID, Worker} ->
%%         ok = Mod:stop(Worker),
%%         close_conns(Rest, lists:keydelete(ID, 1, Workers));
%%
%%      false ->
%%         close_conns(Rest, Workers)
%%   end.
%%
%%incoming(#{id := ID}, Name, _Port, Buf, N) ->
%%   % push out the raw data to whoever needs it
%%   ok = tinyconnect:emit({data, #{id => ID, data => Buf, mod => ?MODULE, type => name()}}, Name),
%%   {continue, N + 1}.
%%
%%do_rescan(#{workers := OldWorkers,
%%            ports := OldPorts,
%%            name := Name,
%%            network := Network} = State) ->
%%
%%   {Added, Removed, NewPorts} = uartchanges(OldPorts, Network),
%%
%%   #{name := Name} = State,
%%   ok = notify_changes({Added, Removed}, Name),
%%
%%   {ok, NewState = #{workers := OldWorkers2}} = autoconnect_ports(Added, State#{ports => NewPorts, workers => OldWorkers}),
%%
%%   NewWorkers = close_conns(Removed, OldWorkers2),
%%
%%   NewState#{workers => NewWorkers}.
%%
%%autoconnect_ports(_Ports, #{network := undefined} = State) -> {ok, State};
%%autoconnect_ports([], State) -> {ok, State};
%%autoconnect_ports([Port|Rest],
%%                  #{network := #{serialport := PortID},
%%                    name    := Name,
%%                    workers := Workers} = State) ->
%%   case Port of
%%      #{id := PortID, path := Path} ->
%%         Callback = fun(P, B, R) -> incoming(Port, Name, P, B, R) end,
%%         NewWorkers = maybe_start_worker(Port, Callback, Workers),
%%
%%         Arg = #{mod => ?MODULE, name => Name, id => PortID, type => name(), path => Path},
%%         _ = (Workers =:= NewWorkers) orelse tinyconnect:emit({open, Arg}, Name),
%%
%%         autoconnect_ports(Rest, State#{workers => NewWorkers});
%%
%%      _ ->
%%         autoconnect_ports(Rest, State)
%%   end.
%%
%%handle_call(rescan, _From, #{} = State) ->
%%   {reply, ok, do_rescan(State)};
%%
%%handle_call(workers, _From, #{workers := Workers} = State) ->
%%   IDs = lists:map(fun({ID, _}) -> ID end, Workers),
%%   {reply, {ok, IDs}, State};
%%
%%handle_call(ports, _From, #{ports := Ports} = State) ->
%%   {reply, {ok, Ports}, State};
%%
%%handle_call({worker, ID}, _From, #{workers := Workers} = State) ->
%%   {reply, get_worker(ID, Workers), State};
%%
%%handle_call({open, ID}, _From, State) ->
%%   with_port(ID, State, fun(Def, #{workers := Workers, name := Name} = State2) ->
%%      Callback = fun(P, B, R) -> incoming(Def, Name, P, B, R) end,
%%
%%      NewWorkers = maybe_start_worker(Def, Callback, Workers),
%%      Path = maps:get(path, Def),
%%      Arg = #{mod => ?MODULE, name => Name, id => ID, type => name(), path => Path},
%%      _ = (Workers =:= NewWorkers) orelse tinyconnect:emit({open, Arg}, Name),
%%
%%      {ok, State2#{workers => NewWorkers}}
%%   end);
%%handle_call({close, ID}, _From, State) ->
%%   with_port(ID, State, fun(Def, #{workers := Workers, name := Name} = State2) ->
%%
%%      NewWorkers = stop_worker(Def, Workers),
%%      Arg = #{id => ID, mod => ?MODULE, type => name()},
%%      _ = (Workers =:= NewWorkers) orelse tinyconnect:emit({close, Arg}, Name),
%%
%%      {ok, State2#{workers := NewWorkers}}
%%   end);
%%
%%handle_call(discover, _From, State) ->          {reply, uart_discover_not_implemented, State};
%%handle_call({identify, _Port}, _From, State) -> {reply, uart_identify_not_implemented, State};
%%handle_call(stop, _From, State) -> {stop, normal, ok, State}.
%%
%%handle_cast(nil, State) ->
%%   {noreply, State}.
%%
%%%handle_info({'DOWN', _Ref, process, PID, Reason}, #{workers := Workers} = State) ->
%%handle_info({'EXIT', PID, Reason}, #{workers := Workers} = State) ->
%%   case lists:keyfind(PID, 2, Workers) of
%%      {ID, PID} ->
%%         error_logger:info_msg("handler-uart/discover: ~s's worker terminated: ~p", [ID, Reason]),
%%         NewWorkers = lists:keydelete(PID, 2, Workers),
%%         {noreply, State#{workers => NewWorkers}};
%%
%%      false ->
%%         {noreply, State}
%%   end;
%%handle_info(rescan, State) ->
%%   Interval = application:get_env(tinyconnect, rescan_interval, 5000),
%%   timer:send_after(Interval, rescan),
%%
%%   {noreply, do_rescan(State)};
%%% returned from tty handler
%%handle_info({_PID, open}, State) -> {noreply, State};
%%
%%handle_info({'$tinyconnect', [_, <<"open">>]  = Ev, Args}, State) -> {noreply, open(Ev, Args, State)};
%%handle_info({'$tinyconnect', [_, <<"close">>] = Ev, Args}, State) -> {noreply, close(Ev, Args, State)};
%%handle_info({'$tinyconnect', [_, <<"data">>]  = Ev, Args}, State) -> {noreply, data(Ev, Args, State)}.
%%
%%
%%%% tinyconnect events
%%open([_Who,  <<"open">>],  _Arg, State) -> State.
%%close([_Who, <<"close">>], _Arg, State) -> State.
%%data([_Who,  <<"data">>],  #{id := ID, data := Buf}, #{workers := Workers} = State) ->
%%   {reply, _, State} = with_port(ID, State, fun(#{mod := Mod}, State2) ->
%%      case get_worker(ID, Workers) of
%%         {ok, {ID, Worker}} ->
%%            Mod:send(Buf, Worker),
%%            {ok, State2};
%%
%%         _ ->
%%            {ok, State2}
%%      end
%%   end),
%%   State.
%%
%%
%%terminate(_Reason, _State) -> ok.
%%
%%code_change(_OldVsn, _NewVsn, State) -> {ok, State}.
%%
%%
%%%% private functions
%%
%%with_port(ID, #{ports := Ports} = State, Callback) ->
%%   case lists:dropwhile(fun(#{id := Match}) -> Match =/= ID end, Ports) of
%%      [] -> {reply, {error, {notfound, {port, ID}}}, State};
%%      [Def | _] ->
%%         {Ret, NewState} = Callback(Def, State),
%%         {reply, Ret, NewState}
%%   end.
%%
%%get_worker(ID, Workers) ->
%%   case lists:keyfind(ID, 1, Workers) of
%%      {ID, _Worker} = Res -> {ok, Res};
%%      false -> {error, {notfound, {worker, ID}}}
%%   end.
%%
%%maybe_start_worker(#{id := ID, path := Path, mod := Mod} = Port, Callback, Workers) ->
%%   case lists:keyfind(ID, 1, Workers) of
%%      {_ID, _Worker} -> Workers;
%%
%%      false ->
%%         Opts = maps:get(serialport_opts, Port, []),
%%         {ok, Worker} = Mod:start_link(Path, Callback, Opts, 0),
%%         [{ID, Worker} | Workers]
%%   end.
%%
%%stop_worker(#{id := ID, mod := Mod}, Workers) ->
%%   case lists:keyfind(ID, 1, Workers) of
%%      {ID, Worker} ->
%%         ok = Mod:stop(Worker),
%%         lists:keydelete(ID, 1, Workers);
%%
%%      false -> Workers
%%   end.
%%
%%portdef({Path, Mod}) ->
%%   ID = to_atom(filename:basename(Path)),
%%   Path2 = Path,
%%   portdef(ID, Path2, Mod);
%%portdef(Path) when is_binary(Path); is_list(Path) ->
%%   portdef({Path, ?TTYMOD}).
%%
%%portdef(ID, Path, Mod) when is_list(Path) -> portdef(ID, iolist_to_binary(Path), Mod);
%%portdef(ID, Path, Mod) ->
%%   #{
%%        id       => ID
%%      , path     => Path
%%      , mod      => Mod
%%      , callback => nil
%%      , tinymesh => {_NID = nil, _SID = nil, _UID = nil}
%%   }.
%%
%%to_atom(<<Buf/binary>>) -> binary_to_atom(Buf, utf8);
%%to_atom([_|_] = Buf) -> list_to_atom(Buf).
%%
%%listports(OldPorts) ->
%%   Type = application:get_env(tinyconnect, os_type, os:type()),
%%   listports(Type, OldPorts).
%%
%%listports({test, PortPaths}, _OldPorts) ->
%%   NewPorts = lists:map( fun(Path) -> portdef(Path) end, PortPaths ),
%%   {ok, NewPorts};
%%
%%listports({unix, _linux}, OldPorts) ->
%%   SearchPaths = ["/dev/serial/by-id/*", "/dev/ttyS*"],
%%   Paths = lists:flatmap(fun filelib:wildcard/1, SearchPaths),
%%
%%   NewPorts = lists:map(
%%      fun(Path) ->
%%         #{id := ID} = Default = portdef(Path),
%%
%%         case lists:filter(fun(#{id := M}) -> ID =:= M end, OldPorts) of
%%            [] -> Default;
%%            [E] -> E
%%         end
%%      end, Paths),
%%   {ok, NewPorts};
%%
%%listports({win32, _nt}, OldPorts) ->
%%   Buf = iolist_to_binary(os:cmd("wmic path Win32_PnPEntity WHERE \"Name LIKE '%USB Serial Port%'\" GET DeviceID,Name")),
%%   case binary:split(Buf, [<<"\n">>, <<"\r">>], [global, trim_all]) of
%%      [] -> {ok, []};
%%      [_Head] -> {ok, []};
%%      [Head | Rest] ->
%%         Keys = re:split(Head, "[ ]{2,}", [trim]),
%%         Res = lists:map(fun(Line) ->
%%            Vals = re:split(Line, "[ ]{2,}", [trim]),
%%            #{<<"Name">> := Name} = maps:from_list(lists:zip(Keys, Vals)),
%%            [_, ID] = binary:split(Name, [<<"(">>, <<")">>], [global, trim]),
%%            ID2 = to_atom(ID),
%%
%%            Default = portdef(ID2, ?TTYMOD, ID),
%%
%%            case lists:filter(fun(#{id := M}) -> ID2 =:= M end, OldPorts) of
%%               [] -> Default;
%%               [E] -> E
%%            end
%%         end, Rest),
%%
%%         {ok, Res}
%%   end.

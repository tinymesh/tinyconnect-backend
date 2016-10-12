-module(tinyconnect_channel2).
-behaviour(gen_server).

-export([
     get/1
   , stop/1
   , update/2
   , emit/4

   , start_link/1
   , init/1
   , handle_call/3
   , handle_cast/2
   , handle_info/2
   , terminate/2
   , code_change/3
]).

-type plugin() :: uuid:uuid().

-spec get(Server :: pid()) -> {ok, tinyconnect_channel:def()} | {error, term()}.
get(Server) -> gen_server:call(Server, get).

-spec stop(Server :: pid()) -> ok | {error, term()}.
stop(Server) -> gen_server:call(Server, stop).

-spec update(Data :: term(), Server :: pid()) -> ok | {error, term()}.
update(Data, Server) -> gen_server:call(Server, {update, Data}).

-spec emit(Server :: pid(), Plugin :: plugin(), atom(), term()) -> ok | {error, term()}.
emit(Server, Plugin, EvType, Ev) ->
   gen_server:cast(Server, {emit, Plugin, EvType, Ev}).

-spec start_link(tinyconnect_channel:def()) -> {ok, pid()} | {error, term()}.
start_link(#{<<"channel">> := _Name} = Def) ->
   gen_server:start_link(?MODULE, Def, []).

-spec init(tinyconnect_channel:def()) -> {ok, tinyconnect_channel:def()}.
init(#{<<"plugins">> := Plugins} = Def) ->
   process_flag(trap_exit, true),

   NewPlugins = lists:map(fun
      (#{<<"name">> := Name, <<"plugin">> := Mod} = PlugDef) ->
         self() ! {start, Name},
         {Mod, undefined, PlugDef}
      end, Plugins),

   {ok, Def#{ <<"plugins">> => NewPlugins,
              <<"pipelines">> => []}}.

handle_call(get, _From, State) -> '@get'(State);
handle_call(stop, _From, State) -> '@stop'(State);
handle_call({update, Data}, _From, State) -> '@update'(Data, State).

handle_cast({emit, Plugin, Ev}, State) ->
   handle_cast({emit, Plugin, event, Ev}, State);
handle_cast({emit, Plugin, EvType, Ev}, State) ->
   '@emit'(Plugin, EvType, Ev, State).

handle_info(failed, State) -> {noreply, State}.

terminate(_Reason, _State) -> ok.

code_change(_OldVsn, _NewVsn, State) -> {ok, State}.

% Implementation server API
'@get'(#{<<"plugins">> := Plugins} = State) ->
   Plugins2 = lists:map(fun serialize_plugin/1, Plugins),
   {reply, State#{<<"plugins">> => Plugins2}, State}.

'@stop'(State) ->
   % @todo 2016-10-06; loop through all plugins and stop them
   {stop, normal, ok, State}.

'@update'(Data, #{<<"plugins">> := _OldPlugs} = State) ->
   {_Added, _Removed, Plugs} = partition_plugs(maps:get(<<"plugins">>, Data, []), State),

   %Changed = length(OldPlugs) - length(Removed) - length(Added),

   Autoconnect = maps:get(<<"autoconnect">>, Data, false),
   Data2 = maps:put(<<"autoconnect">>, Autoconnect, Data),
   Data3 = maps:put(<<"plugins">>, Plugs, Data2),


   #{<<"plugins">> := Plugins} = NewState = 'update-trigger'(maps:to_list(Data3), State),
   Plugins2 = lists:map(fun serialize_plugin/1, Plugins),

   {reply, {ok, #{<<"plugins">> => Plugins2}}, NewState}.

% Emit event `Ev` from plugin `PlugID` onto all other listeners
% Listeners are defined in the channel itself in the form `[c1/a > c1/b, ..]`
% `emit` can not yet send across channels, but that capability may appear in future release
'@emit'(PlugID, EvType, Ev, #{<<"channel">> := Channel} = State) ->
   case action(PlugID, {event, EvType, Ev, #{from => [Channel, PlugID]}}, State) of
      % If nothing is to be done then, do nothing
      ok ->
         {noreply, State};

      stateless ->
         {noreply, State}; % stateless never changes

      % just update state, don't anything at all
      {ok, NewState} ->
         {noreply, NewState};

      {emit, {EvType, Ev}, #{<<"pipeline">> := Pipe}, NewState} ->
         % evaluate an emit down the pipeline chain!
         Meta = #{from => [[Channel, PlugID]]},
         ForwardAction = {event, EvType, Ev, Meta},
         '@emit-pipe'(Pipe, ForwardAction, NewState)
   end.



'@emit-pipe'([], _Action, State) ->
   {noreply, State};

% Emit parallel, emit onto each plugin without updating forward chain.
% this means {:emit, ..} will apply ONLY to that specific plugin pipeline
% like `each`
'@emit-pipe'([{'*', []} | Rest], Action, State) ->
   '@emit-pipe'(Rest, Action, State);

'@emit-pipe'([{'*', [H|T]} | Rest], Action, State) ->
   case '@emit-pipe'([H], Action, State) of
      {noreply, NewState} -> '@emit-pipe'([{'*', T} | Rest], Action, NewState);

      % parallel does not support emitting
      {emit, _NextEv, _PlugDef, NewState} ->
         '@emit-pipe'([{'*', T} | Rest], Action, NewState)
   end;

'@emit-pipe'([Plugins | Rest], Action, State) when is_list(Plugins) ->
   '@emit-pipe'([{'*', Plugins} | Rest], Action, State);

% emit in serial, like `foldl`
'@emit-pipe'([{'>', []} | Rest], Action, State) ->
   '@emit-pipe'(Rest, Action,State);

'@emit-pipe'([{'>', [H|T]} | Rest], {event, Type, Ev, #{from := From} = Meta} = Action,
             #{<<"channel">> := Channel} = State) ->
   Meta2 = Meta#{from => From ++ [[Channel, H]]},
   Action2 = {event, Type, Ev, Meta2},

   case H of
      <<_/binary>> ->
         case '@emit-pipe'([H], Action2, State) of
            {noreply, NewState} ->
               '@emit-pipe'([{'>', T} | Rest], Action2, NewState);

            {emit, {EvType2, Ev2}, _PlugDef, NewState} ->
               ForwardAction = {event, EvType2, Ev2, Meta2},
               '@emit-pipe'([{'>', T} | Rest], ForwardAction, NewState)
         end;

      _ ->
         error_logger:error_msg("serial pipes can not contain anything but plugins (chain: ~p)",
            [pipechain(Action)]),
         {noreply, state}
   end;

'@emit-pipe'([<<Plugin/binary>> | Rest], Action, State) ->
   case action(Plugin, Action, State) of
      ok -> '@emit-pipe'(Rest, Action, State);
      {ok, NewState} -> '@emit-pipe'(Rest, Action, NewState);
      {emit, {_EvType, _Ev}, _PlugDef, _NewState} = X -> X
   end.

pipechain({event, _Type, _Ev, #{from := From}}) ->
   [_|R] = lists:reverse(lists:flatmap(fun([A, B]) -> [A, "/", B, " -> "] end, From)),
   lists:reverse(R).

% find plugin, and call action/2 on it
action(PlugID, Action, #{<<"channel">> := Channel, <<"plugins">> := Plugins} = State) ->
   case plugin_by_id(PlugID, Plugins) of
      {_Head, []} ->
         {error, {notfound, {<<"plugin">>, [Channel, PlugID]}}};

       {Head, [{Mod, _OldPlugState, #{<<"id">> := ID} = Def} = P | Tail]} ->
         case call_action(P, Action) of
            % Plugin did nothing commemorable
            ok -> {ok, State};

            {state, _State} = NewPlugState ->
               {ok, State#{<<"plugins">> => Head ++ [{Mod, NewPlugState, Def} | Tail]}};

            {emit, EvType, Ev, NewPlugState} ->
               NewState = State#{<<"plugins">> => Head ++ [{Mod, {state, NewPlugState}, Def} | Tail]},
               {emit, {EvType, Ev}, Def, NewState};

            X ->
               error_logger:error_msg("plugin ~s/~s invalid return:~n~p~nplugin may be in invalid state~n", [
                  Channel, ID, X]),

               {ok, State}
         end
   end.

call_action({Target, PlugState, PlugDef}, Action) ->
   Handler = case Target of
      Target when is_function(Target, 2) -> Target;
      Target when is_atom(Target) -> fun Target:handle/2
   end,

   case PlugState of
      undefined -> Handler(Action, nostate);
      stateless -> Handler(Action, nostate);
      {state, State} -> Handler(Action, State)
   end.

'update-trigger'([], State) -> State;

'update-trigger'([{<<"plugins">>, Plugins} | Rest], State) ->
   Plugins2 = lists:map(fun(M) -> start_plugin(M, State) end, Plugins),
   'update-trigger'(Rest, State#{<<"plugins">> => Plugins2});

'update-trigger'([_ | Rest], State) -> 'update-trigger'(Rest, State).

serialize_plugin({_, _PlugState, PlugDef} = Plug) ->
   case (catch call_action(Plug, serialize)) of
      ok -> PlugDef;

      {ok, Serialized} ->
         maps:put(<<"state">>, Serialized, PlugDef);

      % optimistic approach to see if serialized is supported
      {'EXIT', {function_clause, _}} ->
         PlugDef
   end.

% It's a PID! maybe start the thing...
start_plugin({_Plugin, {state, PID}, #{<<"id">> := _ID} = PlugDef} = Plug, State)
      when is_pid(PID) ->

   case is_process_alive(PID) of
      true -> Plug;
      false -> start_plugin2(PlugDef, State)
   end;
start_plugin({_Plugin, {state, _}, #{<<"id">> := _ID}} = Plug, _State) ->
   Plug;
start_plugin({_Plugin, undefined, #{<<"id">> := _ID} = PlugDef}, State) ->
   start_plugin2(PlugDef, State);
start_plugin({_Plugin, stateless, #{<<"id">> := _ID}} = Plug, _State) ->
   Plug.

start_plugin2(PlugDef, #{<<"channel">> := Channel}) ->
   Plugin = maps:get(<<"plugin">>, PlugDef),
   Handler = case Plugin of
      Fun when is_function(Fun, 2) ->
         Fun;

      Module ->
         fun Module:handle/2
   end,

   case Handler({start, Channel, PlugDef}, nostate) of
      % Start a stateless plugin (no state is hold)
      ok -> {Plugin, stateless, PlugDef};

      % Start a stateful plugin
      {ok, PID} when is_pid(PID) -> {Plugin, {state, PID}, PlugDef};

      % Start a stateless agent plugin (all state is hold outside)
      {ok, PlugState} -> {Plugin, {state, PlugState}, PlugDef}
   end.

% Partition-merge new plugin data into `{Added, Removed, NewPlugins}`
partition_plugs(Plugins, #{<<"plugins">> := Existing}) ->
   {Added, _, Existing2} = partition_plugs(Plugins, {[], [], Existing}),
   % find anything that is NOT in `Plugins` or `Added`
   Coll = Added ++ Plugins,
   Removed = lists:filter(fun
      ({_, _, #{<<"id">> := ID}}) ->
         lists:all(fun
            (#{<<"id">> := EID}) -> ID =/= EID;
            (#{}) -> false
         end, Coll)
   end, Existing),

   {Added, Removed, Existing2 -- Removed};

partition_plugs([], {Add, Rem, All}) -> {Add, Rem, lists:reverse(All)};

partition_plugs([#{<<"id">> := ID} = PlugUpdate | Rest], {Add, Rem, All} = Acc) ->
   case plugin_by_id(ID, All) of
      {_, []} ->
         error_logger:error_msg("can't update a non-existing plugin: ~s", [ID]),
         partition_plugs(Rest, Acc);

      {Head, [{Mod, PlugState, _OldPlugDef} | Tail]} ->
         % @todo 2016-10-06; maybe require plugin to restart
         %error_logger:info_msg("updating plugin ~s: ~p", [ID, PlugUpdate]),
         NewAcc = {Add, Rem, Head ++ [{Mod, PlugState, PlugUpdate} | Tail]},
         partition_plugs(Rest, NewAcc)
   end;

partition_plugs([#{} = Plug | Rest], {Add, Rem, All}) ->
   % things without a id means a new plugin!
   Plug2 = maps:put(<<"id">>, uuid:uuid(), Plug),
   SupDef = {undefined, undefined, Plug2},
   partition_plugs(Rest, {[SupDef | Add], Rem, [SupDef | All]}).

% Returns tuple {A, B} where
%  B := [] when plugin not found
%  B := [P | R] when plugin P was found
plugin_by_id(ID, Plugins) ->
   lists:splitwith(
      fun({_Mod, _State, #{<<"id">> := PlugID}}) -> ID =/= PlugID end,
      Plugins).

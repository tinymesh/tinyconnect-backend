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
-type server() :: pid() | {global, term()}.

-spec get(server()) -> {ok, tinyconnect_channel:extdef()} | {error, term()}.
get(Server) -> gen_server:call(Server, get).

-spec stop(server()) -> ok | {error, term()}.
stop(Server) -> gen_server:call(Server, stop).

-spec update(Data :: term(), server()) -> {ok, tinyconnect_channel:extdef()} | {error, term()}.
update(Data, Server) -> gen_server:call(Server, {update, Data}).

-spec emit(server(), Plugin :: plugin(), atom(), term()) -> ok.
emit(Server, Plugin, EvType, Ev) ->
   gen_server:cast(Server, {emit, Plugin, EvType, Ev}).

-spec start_link(tinyconnect_channel:extdef()) -> {ok, pid()} | {error, term()}.
start_link(#{<<"channel">> := Name} = Def) ->
   gen_server:start_link({global, Name}, ?MODULE, Def, []).

-spec init(tinyconnect_channel:extdef()) -> {ok, tinyconnect_channel:extdef()}.
init(#{<<"plugins">> := Plugins} = Def) ->
   process_flag(trap_exit, true),

   NewPlugins = lists:map(fun
      (#{<<"plugin">> := Mod} = PlugDef) ->
         PlugID = maps:get(<<"id">>, PlugDef, uuid:uuid()),
         PlugDef2 = maps:put(<<"id">>, PlugID, PlugDef),
         {Mod, undefined, PlugDef2}
      end, Plugins),

   NewState = Def#{ <<"plugins">> => NewPlugins },
   NewPlugins2 = lists:map(fun(P) -> start_plugin(P, NewState) end, NewPlugins),
   {ok, NewState#{<<"plugins">> => NewPlugins2}}.

handle_call(get, _From, State) -> '@get'(State);
handle_call(stop, _From, State) -> '@stop'(State);
handle_call({update, Data}, _From, State) -> '@update'(Data, State).

handle_cast({emit, Plugin, Ev}, State) ->
   handle_cast({emit, Plugin, event, Ev}, State);
handle_cast({emit, Plugin, EvType, Ev}, State) ->
   '@emit'(Plugin, EvType, Ev, State).

handle_info(_, State) -> {noreply, State}.

terminate(_Reason, _State) -> ok.

code_change(_OldVsn, _NewVsn, State) -> {ok, State}.

% Implementation server API
'@get'(#{<<"plugins">> := Plugins} = State) ->
   Plugins2 = lists:map(fun serialize_plugin/1, Plugins),

   RetState = State#{
      <<"plugins">> => Plugins2,
      <<"state">> => state_from_plugins(Plugins)},

   {reply, {ok, RetState}, State}.

state_from_plugins([]) -> started;
state_from_plugins([{_, {error, _}, _} | _Rest]) -> error;
state_from_plugins([{_, undefined, _} | _Rest]) -> stopped;
state_from_plugins([{_, stateless, _} | Rest]) -> state_from_plugins(Rest);
state_from_plugins([{_, {state, _}, _} | Rest]) -> state_from_plugins(Rest).

'@stop'(State) ->
   % @todo 2016-10-06; loop through all plugins and stop them
   {stop, normal, ok, State}.

'@update'(Data, #{<<"plugins">> := _OldPlugs} = State) ->
   {Added, Changed, Removed, Plugs} = partition_plugs(maps:get(<<"plugins">>, Data, []), State),

   _ = lager:debug("new plugins... changed: ~p, added: ~p, removed: ~p", [
                                                                 length(Changed),
                                                                 length(Added),
                                                                 length(Removed)]),

   Autoconnect = maps:get(<<"autoconnect">>, Data, false),
   Data2 = maps:put(<<"autoconnect">>, Autoconnect, Data),
   Data3 = maps:put(<<"plugins">>, lists:reverse(Plugs), Data2),


   case 'update-trigger'(maps:to_list(Data3), State) of
      {ok, #{<<"plugins">> := Plugins} = NewState} ->
         Plugins2 = lists:map(fun serialize_plugin/1, Plugins),

         {reply, {ok, NewState#{<<"plugins">> => lists:reverse(Plugins2)}}, NewState};

      {error, _} = Err ->
         {reply, Err, State}
   end.

% Emit event `Ev` from plugin `PlugID` onto all other listeners
% Listeners are defined in the channel itself in the form `[c1/a > c1/b, ..]`
% `emit` can not yet send across channels, but that capability may appear in future release
'@emit'(PlugID, EvType, Ev, #{<<"channel">> := Channel, <<"plugins">> := Plugins} = State) ->
   %case action(PlugID, {event, EvType, Ev, #{from => [Channel, PlugID]}}, State) of
   %   % If nothing is to be done then, do nothing
   %   ok ->
   %      {noreply, State};

   %   stateless ->
   %      {noreply, State}; % stateless never changes

   %   % just update state, don't anything at all
   %   {ok, NewState} ->
   %      {noreply, NewState};

   %   {emit, {EvType, Ev}, #{<<"pipeline">> := Pipe}, NewState} ->
   %      % evaluate an emit down the pipeline chain!
   %      Meta = #{from => [[Channel, PlugID]]},
   %      ForwardAction = {event, EvType, Ev, Meta},
   %      '@emit-pipe'(Pipe, ForwardAction, NewState)
   %end.
   case plugin_by_id(PlugID, Plugins) of
      false ->
         {noreply, State};

       {_Head, [{_Handler, _OldPlugState, #{<<"id">> := ID,
                                            <<"pipeline">> := Pipeline}} | _Tail]} ->

            Meta = #{from => [[Channel, ID]]},
            '@emit-pipe'(Pipeline, {event, EvType, Ev, Meta}, State);

       {_Head, [{_Mod, _OldPlugState, #{}} | _Tail]} ->
         {noreply, State}
   end.



'@emit-pipe'([], _Action, State) ->
   {noreply, State};

% Emit parallel, emit onto each plugin without updating forward chain.
% this means {:emit, ..} will apply ONLY to that specific plugin pipeline
% like `each`
'@emit-pipe'([<<"parallel">>], Action, State) ->
   '@emit-pipe'([], Action, State);

'@emit-pipe'([<<"parallel">>, H | Rest], Action, State) ->
   case '@emit-pipe'([H], Action, State) of
      {noreply, NewState} ->
         '@emit-pipe'([<<"parallel">> | Rest], Action, NewState);

      % parallel does not support emitting
      {emit, _NextEv, _PlugDef, NewState} ->
         '@emit-pipe'([<<"parallel">> | Rest], Action, NewState)
   end;

% emit in serial, like `foldl`
'@emit-pipe'([<<"serial">>], Action, State) ->
   '@emit-pipe'([], Action, State);

'@emit-pipe'([<<"serial">>, H | Rest], {event, Type, Ev, #{from := From} = Meta} = Action,
             #{<<"channel">> := Channel} = State) ->

   Meta2 = Meta#{from => From ++ [[Channel, H]]},
   Action2 = {event, Type, Ev, Meta2},

   case H of
      <<_/binary>> ->
         case '@emit-pipe'([H], Action2, State) of
            {noreply, NewState} ->
               '@emit-pipe'([<<"serial">> | Rest], Action2, NewState);

            {emit, {EvType2, Ev2}, _PlugDef, NewState} ->
               ForwardAction = {event, EvType2, Ev2, Meta2},
               '@emit-pipe'([<<"serial">> |  Rest], ForwardAction, NewState)
         end;

      _ ->
         error_logger:error_msg("serial pipes can not contain anything but plugins (chain: ~p)",
            [pipechain(Action)]),
         {noreply, state}
   end;

'@emit-pipe'([[<<"serial">> | _] = Items | Rest], Action, State) ->
   case '@emit-pipe'(Items, Action, State) of
      {noreply, NewState} ->
         '@emit-pipe'(Rest, Action, NewState)
   end;

'@emit-pipe'([[<<"parallel">> | _] = Items | Rest], Action, State) ->
   case '@emit-pipe'(Items, Action, State) of
      {noreply, NewState} ->
         '@emit-pipe'(Rest, Action, NewState)
   end;

'@emit-pipe'([<<Plugin/binary>> | Rest], Action, State) ->
   {event, T, Ev, #{from := F}} = Action,
   [[X2|_]|R] = lists:reverse(lists:map(fun([_Chan,Plug]) -> [Plug, " -> "] end, F)),
   From = iolist_to_binary(lists:reverse([X2|R])),

   _ = lager:debug("channel2: @emit-pipe ~p/~p <~~ ~s", [T, Ev, From]),

   case action(Plugin, Action, State) of
      {ok, NewState} -> '@emit-pipe'(Rest, Action, NewState);
      {emit, {_EvType, _Ev}, _PlugDef, _NewState} = X -> X;
      {error, {args, _}} -> '@emit-pipe'(Rest, Action, State)
   end.

pipechain({event, _Type, _Ev, #{from := From}}) ->
   [_|R] = lists:reverse(lists:flatmap(fun([A, B]) -> [A, "/", B, " -> "] end, From)),
   lists:reverse(R).

% find plugin, and call action/2 on it
action(PlugID, Action, #{<<"channel">> := Channel, <<"plugins">> := Plugins} = State) ->
   case first([plugin_by_id(PlugID, Plugins), plugin_by_name(PlugID, Plugins)]) of
      false ->
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

            {error, {args, _Args}} = Err ->
               Err;

            X ->
               error_logger:error_msg("plugin ~s/~s invalid return:~n~p~nplugin may be in invalid state~n", [
                  Channel, ID, X]),

               {ok, State}
         end
   end.

first([]) -> false;
first([false | Rest]) -> first(Rest);
first([X|_]) -> X.


call_action({Target, PlugState, PlugDef}, Action) ->
   Handler = case Target of
      Target when is_function(Target, 2) -> Target;
      Target when is_atom(Target) -> fun Target:handle/2
   end,

   case PlugState of
      {error, {args, _Args}} = E -> E;
      undefined -> Handler(Action, nostate);
      stateless -> Handler(Action, nostate);
      {state, State} -> Handler(Action, State)
   end.

'update-trigger'([], State) -> {ok, State};

'update-trigger'([{<<"plugins">>, Plugins} | Rest], #{<<"plugins">> := CurrPlugins} = State) ->
   Plugins2 = lists:map(fun({_Plug, _PlugState, NewPlugDef} = M) ->
      % start or update plugin
      MatchID = maps:get(<<"id">>, NewPlugDef, none),
      case lists:filter(fun
               ({_, _, #{<<"id">> := ID}}) -> ID =:= MatchID;
               ({_, _, #{}}) -> false
           end,  CurrPlugins) of

         [] -> start_plugin(M, State);
         [{Mod, CurrPlugState, _CurrPlugDef} = CurrPlugin] ->
            case call_action(CurrPlugin, {update, NewPlugDef, State}) of
               ok -> CurrPlugin;
               {ok, NewPlugDef} -> {Mod, CurrPlugState, NewPlugDef};
               {error, _E} -> CurrPlugin;
               {'EXIT', {function_clause, _}} -> CurrPlugin;
               X ->
                  error_logger:error_msg("invalid plugin return for ~p: ~p", [Mod, X]),
                  CurrPlugin
            end
      end
   end, Plugins),
'update-trigger'(Rest, State#{<<"plugins">> => Plugins2});

'update-trigger'([{<<"name">>, Name} | Rest], State)      -> 'update-trigger'(Rest, State#{<<"name">> => Name});
'update-trigger'([{<<"autoconnect">>, AC} | Rest], State) ->
   % the system assumes that channel and all it's plugins should be alive
   % meaning for now that autoconnect is implicitly true regardless of it's
   % actual value.
   % In the future
   %   on transition:
   %    false > true -> notify plugins to start
   %    true > false -> nothing
   'update-trigger'(Rest, State#{<<"autoconnect">> => AC});
'update-trigger'([{<<"channel">>, _} | Rest], State)      -> 'update-trigger'(Rest, State);
'update-trigger'([{<<"source">>, _} | Rest], State)       -> 'update-trigger'(Rest, State);
'update-trigger'([{<<"state">>, _} | Rest], State)        ->
   % nothing definition actual state, it's just assumed that every existing
   % channel should be started. @todo will be improved in future
   'update-trigger'(Rest, State);



'update-trigger'([{K, _} | _Rest], _State) ->
   {error, #{<<"invalidkey">> => K}}.

serialize_plugin({T, _PlugState, PlugDef} = Plug) ->
   case (catch call_action(Plug, serialize)) of
      ok -> PlugDef;

      {ok, Serialized} ->
         maps:put(<<"state">>, Serialized, PlugDef);

      {error, {args, Args}} ->
         Args2 = lists:foldl(fun(K, Acc) ->
            maps:put(join(K, <<".">>), maps:get(K, Args), Acc)
         end, #{}, maps:keys(Args)),
         maps:put(<<"state">>, #{<<"error">> => #{<<"args">> => Args2}}, PlugDef);

      % optimistic approach to see if serialized is supported
      {'EXIT', {function_clause, _}} ->
         PlugDef;

      X ->
         error_logger:error_msg("invalid plugin return for ~p: ~p", [T, X]),
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
   Plugin = maps:get(<<"plugin">>, PlugDef, undefined),
   Handler = case Plugin of
      undefined ->
         fun(_, _) -> {error, noplugarg} end;

      <<Plugin/binary>> ->
         case binary:split(Plugin, <<":">>) of
            [M, F] ->
               Mod = binary_to_existing_atom(M, utf8),
               [F2|_] = binary:split(F, <<"/">>),
               Fun = binary_to_existing_atom(F2, utf8),
               fun Mod:Fun/2;

            [MF] ->
               case binary:split(MF, <<"/">>) of
                  [F, _A] ->
                     Fun = binary_to_existing_atom(F, utf8),
                     fun tinyconnect_plugins:Fun/2;

                  [M] ->
                     Mod = binary_to_existing_atom(M, utf8),
                     fun Mod:handle/2
               end
         end;

      Fun when is_function(Fun, 2) ->
         Fun;

      Module when is_atom(Module) ->
         fun Module:handle/2;

      Fun when is_function(Fun) ->
         fun(_, _) -> {error, invalid_plugin_arg} end
   end,

   case Handler({start, Channel, PlugDef}, nostate) of
      % Start a stateless plugin (no state is hold)
      ok -> {Handler, stateless, PlugDef};

      % Start a stateful plugin
      {ok, PID} when is_pid(PID) -> {Handler, {state, PID}, PlugDef};

      % Start a stateless agent plugin (all state is hold outside)
      {ok, PlugState} -> {Handler, {state, PlugState}, PlugDef};

      % Plugin can't start due to input arguments
      {error, {args, Args}} ->
         {Handler, {error, {args, Args}}, PlugDef};

      {error, _E2} = Err ->
         _ = lager:error("failed to start plugin ~p invalid return: ~p", [Handler, Err]),
         {Handler, Err, PlugDef}
   end.

% Partition-merge new plugin data into `{Added, Removed, NewPlugins}`
partition_plugs(Plugins, #{<<"plugins">> := Existing}) ->
   {Added, Change, Existing2} = partition_plugs(Plugins, {[], [], Existing}),
   % find anything that is NOT in `Plugins` or `Added`
   Removed = (Existing2 -- Added) -- Change,

   {Added, Change, Removed, Existing2 -- Removed};

partition_plugs([], {Add, Rem, All}) -> {Add, Rem, lists:reverse(All)};

partition_plugs([#{<<"id">> := ID} = PlugUpdate | Rest], {Add, Change, All} = Acc) ->
   case plugin_by_id(ID, All) of
      false ->
         error_logger:error_msg("can't update a non-existing plugin: ~s", [ID]),
         partition_plugs(Rest, Acc);

      {Head, [{Mod, PlugState, _OldPlugDef} | Tail]} ->
         % @todo 2016-10-06; maybe require plugin to restart
         Def = {Mod, PlugState, PlugUpdate},
         NewAcc = {Add, [Def | Change], Head ++ [Def | Tail]},
         partition_plugs(Rest, NewAcc)
   end;

partition_plugs([#{} = Plug | Rest], {Add, Change, All}) ->
   % things without a id means a new plugin!
   Plug2 = maps:put(<<"id">>, uuid:uuid(), Plug),
   SupDef = {undefined, undefined, Plug2},
   partition_plugs(Rest, {[SupDef | Add], Change, [SupDef | All]}).

% Returns tuple {A, B} where
%  B := [] when plugin not found
%  B := [P | R] when plugin P was found
plugin_by_id(ID, Plugins) ->
   case lists:splitwith(
      fun({_Mod, _State, #{<<"id">> := PlugID}}) -> ID =/= PlugID end,
      Plugins) of

      {_, []} -> false;
      Return -> Return
   end.

plugin_by_name(Name, Plugins) ->
   case lists:splitwith(
      fun
         ({_Mod, _State, #{<<"name">> := PlugName}}) -> Name =/= PlugName;
         (_) -> false end,
      Plugins) of

      {_, []} -> false;
      Return -> Return
   end.

join([], _Sep) -> <<>>;
join([Part], _Sep) -> Part;
join([Head|Tail], Sep) ->
  lists:foldl(fun(Value, Acc) -> <<Acc/binary, Sep/binary, Value/binary>> end, Head, Tail).

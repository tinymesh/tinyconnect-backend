-module(tinyconnect_channel).
-behaviour(gen_server).

-export([
   % utilities for plugins
     defaultplug/1
   , subscribe/2
   , emit/4

   % server API
   , get/1
   , stop/1

   % gen_server callbacks
   , start_link/1
   , init/1
   , handle_call/3
   , handle_cast/2
   , handle_info/2
   , terminate/2
   , code_change/3
]).


-export_type([
     channel/0
   , def/0
   , plugin/0
]).

-type eventtype() :: open
                   | close
                   | data.

-type event() :: #{}.
-type channel() :: binary().
-type plugin() :: #{
   channel => Name :: channel(),
   % name of plugin instance
   name => Name :: atom(),
   % what sources to subscribe to events from
   subscribe => [channel() | {channel(), [PlugName :: binary()]}],
   % the module to handle tty connections
   handler => module(),
   % opts for gen_server
   opts => term(),
   % list of `(Chan, Plugin)` defs to wait for
   start_after => [],
   backoff => {TimerRef :: reference() | undefined, undefined | backoff:backoff()}
}.

-type plugindef() :: tinyconnect_handler_uart:def()
                   | #{name => binary()}.
-type plugin_entry() :: {Mod :: module(), plugindef()}.
-type def() :: #{
   channel => channel(),
   autoconnect => true | false,
   plugins => [plugin_entry() | plugin_entry()] | [],
   source => user | config | uart
}.

% some generic utilities for the plugin

defaultplug(Channel) ->
   #{
      channel => Channel,
      % sources to subscribe to events from
      subscribe => [],
      % opts for gen_server
      opts => [],
      % list of `Chan | (Chan, Plugin)` defs to wait for
      start_after => [],
      % restart backoff
      backoff => {undefined, backoff:init(1000, 300000)}
   }.


% Subscribe can either subscribe to a channel `[<chan>]`,
% a set of plugins for a channel `[<chan>, <plugin>]` OR
% all plugins for a channel `[<chan>, _]`
-spec subscribe(ChanOrPlugin :: [channel()|binary()],
                ChanOrPluginDef :: def() | plugindef()) -> ok.
subscribe(Caller, #{subscribe := Subscriptions}) ->
   subscribe2(Caller, Subscriptions);
subscribe(_Caller, #{}) -> ok.

subscribe2(_Caller, []) -> ok;
subscribe2(Caller, [{Chan, Plugins} | Rest]) ->
   lists:foreach(fun
      (Match) when Match =:= Caller -> ok;
      (Group) ->
         ok = pg2:create([Chan, Group]),
         ok = pg2:join([Chan, Group], self())
   end, Plugins),

   subscribe2(Caller, Rest);

% Skip subscribing to ourselves
subscribe2(Caller, [Caller | Rest]) -> subscribe2(Caller, Rest);
subscribe2(Caller, [Channel | Rest]) ->
   ok = pg2:create([Channel]),
   ok = pg2:join([Channel], self()),

   subscribe2(Caller, Rest).


% Emits events onto the groups used by `subscribe`
-spec emit(ChanOrPlug :: [channel()|binary()],
           ChanOrPluginDef :: def() | plugindef(),
           Type :: eventtype(),
           Event :: event()) -> ok.

emit([Chan, Plugin] = Group, #{}, Type, Event) ->
   lists:foreach(fun(PID) ->
      PID ! {'$tinyconnect', [Chan, Plugin], maps:put(type, Type, Event)}
   end, get_pg2_members(Group));

emit([Chan] = Group, #{}, Type, Event) ->
   lists:foreach(fun(PID) ->
      PID ! {'$tinyconnect', [Chan], maps:put(type, Type, Event)}
   end, get_pg2_members(Group)).

get_pg2_members(Group) ->
   case pg2:get_members(Group) of
      {error, {no_such_group, _}} -> [];
      Pids -> Pids
   end.



-spec get(Server :: pid()) -> {ok, def()} | {error, term()}.
get(Server) -> gen_server:call(Server, get).

-spec stop(Server :: pid()) -> ok | {error, term()}.
stop(Server) -> gen_server:call(Server, stop).

-spec start_link([def()]) -> {ok, pid()} | {error, term()}.
start_link(#{channel := _Name} = Def) ->
   gen_server:start_link(?MODULE, Def, []).

-spec init([def()]) -> {ok, pid()} | {error, term()}.
init(#{plugins := Plugins, channel := Channel} = Def) ->
   process_flag(trap_exit, true),

   NewPlugins = lists:map(fun({Mod, #{name := Name} = PlugDef}) ->
      self() ! {start, Name},
      {Mod, undefined, maps:merge(defaultplug(Channel), PlugDef)}
   end, Plugins),

   {ok, Def#{plugins => NewPlugins}}.


handle_call(get, _From, State) -> def(State);
handle_call(stop, _From, State) -> {stop, normal, ok, State}.

handle_cast(nil, State) -> {noreply, State}.

% optimistic supervision.
% Restarts may be dependant but SHOULD always happen sometime infuture.
% The plugins may freely link AND monitor each other but we need an
% flexible way to say:
%  - restart <P> with backoff
%  - restart <P1> once <P2> (re)starts
handle_info({start, Name}, State) ->
   case start_plugin(Name, State) of
      {started, NewState, StartNext} ->
         lists:foreach(fun(E) -> self() ! {start, E} end, StartNext),
         {noreply, NewState};

      {failed, NewState} ->
         {noreply, NewState};

      {stale, NewState} ->
         {noreply, NewState};

      {notfound, NewState} ->
         {noreply, NewState}
   end;

handle_info({'EXIT', PID, Reason}, #{plugins := Plugins} = State) ->
   case lists:keyfind(PID, 2, Plugins) of
      {Mod, PID, #{backoff := {undefined, Backoff}, channel := Chan, name := Name} = PlugDef} ->
         error_logger:error_msg("plugin[~s :: ~s/~s] failed to start:~n~p~n",
                                [Mod, Chan, Name, Reason]),

         {Delay, NewBackoff} = backoff:fail(Backoff),
         Timer = erlang:send_after(Delay, self(), {start, Name}),

         NewPlugDef = PlugDef#{backoff => {Timer, NewBackoff}},
         NewPlugins = lists:keyreplace(PID, 2, Plugins, {Mod, undefined, NewPlugDef}),

         {noreply, State#{plugins => NewPlugins}};

      {Mod, PID, #{backoff := {Timer, _B}, channel := Chan, name := Name}} when is_reference(Timer) ->
         error_logger:error_msg("plugin[~s :: ~s/~s] failed to start:~n~p~n",
                                [Mod, Chan, Name, Reason]),

         {noreply, State};

      false ->
         {noreply, State}
   end.

terminate(_Reason, _State) -> ok.

code_change(_OldVsn, _NewVsn, State) -> {ok, State}.

def(State) -> {reply, {ok, State}, State}.

start_plugin(Name, #{plugins := Plugins, channel := Chan} = State) ->
   case lists:splitwith(fun({_Mod, _State, #{name := PlugName}}) ->
                           Name =/= PlugName
                        end,
                        Plugins) of

      {_, []} ->
         %error_logger:warning_msg(
         %   "channel[~s]: failed to start plugin ~s, no such plugin",
         %   [Chan, Name]),
         {notfound, State};

      {_Head, [{_Mod, PID, _PluginDef} | _Tail]} when is_pid(PID) ->
         %error_logger:info_msg(
         %   "channel[~s]: not starting plugin ~s, already running: ~p",
         %   [Chan, Name, PID]),
         {started, State, plugin_start_next(Plugins)};

      {Head, [{Mod, undefined, #{backoff := {Timer, Backoff}, name := Name} = PluginDef} | Tail]} ->
         CanStart = plugin_can_start(Mod, PluginDef, Plugins),
         if CanStart ->
            case Mod:start_link(Chan, PluginDef) of
               {ok, PID} ->
                  if is_reference(Timer) -> erlang:cancel_timer(Timer);
                     true -> ok end,
                  {_Delay, NewBackoff} = backoff:succeed(Backoff),
                  NewPluginDef = PluginDef#{backoff => {undefined, NewBackoff}},
                  NewPlugins  = Head ++ [{Mod, PID, NewPluginDef} | Tail],

                  {started, State#{plugins => NewPlugins}, plugin_start_next(NewPlugins)};

               {error, Reason} ->
                  error_logger:error_msg("plugin[~s :: ~s/~s] failed to start:~n~p~n",
                                         [Mod, Chan, Name, Reason]),

                  {Delay, NewBackoff} = backoff:fail(Backoff),
                  NewTimer = erlang:send_after(Delay, self(), {start, Name}),
                  NewPluginDef = PluginDef#{backoff => {NewTimer, NewBackoff}},
                  {failed, State#{plugins => Head ++ [{Mod, undefined, NewPluginDef} | Tail]}}
            end;
         true ->
            {stale, State}
         end
   end.

plugin_can_start(_Mod,
                 #{start_after := After} = _PluginDef,
                 Plugins) ->

   lists:all(
      fun(P) ->
         lists:any(fun({_,Running,#{name := P2}}) -> P =:= P2 andalso Running =/= undefined end,
                   Plugins)
      end,
      After).

% Find plugins which may be started; according to start_after
plugin_start_next(Plugins) ->
   {Started, Stopped} = partition_map(fun({_Mod, PID, _}) ->
      PID =/= undefined
   end, Plugins, fun({_, _, PluginDef}) -> PluginDef end),

   plugin_start_next(Plugins, {Started, Stopped}, []).

plugin_start_next([], _, Acc) -> Acc;
plugin_start_next([{_, _, #{start_after := Deps, name := Name}} | Rest],
                  {Started, Stopped}, Acc) ->
   HasStopped  = lists:any(fun(#{name := N}) -> N =:= Name end, Stopped),
   DepsStarted = lists:all(fun(Dep) ->
                     lists:any(fun(#{name := N}) -> N =:= Dep end, Started)
                 end, Deps),

   case HasStopped andalso DepsStarted of
      true  -> plugin_start_next(Rest, {Started, Stopped}, [Name | Acc]);
      false -> plugin_start_next(Rest, {Started, Stopped}, Acc)
   end.

partition_map(Pred, L, Mapper) ->
    partition_map(Pred, L, [], [], Mapper).

partition_map(Pred, [H | T], As, Bs, Mapper) ->
   case Pred(H) of
      true -> partition_map(Pred, T, [Mapper(H) | As], Bs, Mapper);
      false -> partition_map(Pred, T, As, [Mapper(H) | Bs], Mapper)
   end;
partition_map(Pred, [], As, Bs, _Mapper) when is_function(Pred, 1) ->
   {lists:reverse(As), lists:reverse(Bs)}.


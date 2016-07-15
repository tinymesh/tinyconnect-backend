-module(tinyconnect).
-behaviour(supervisor).
-behaviour(application).

-export([
     init/1
   , start/2
   , stop/1

   , main/1

   , emit/2
]).


-define(OUTQUEUE, tinyconnect_out_queue).

start(_, _) ->
   %Plugins = [
   %   {tinyconnect_handler_uart,      [tinyconnect_handler_uart:name(),
   %                                    [{subscribe, [cloudsync, uartproxy]}] ]}
   % , {tinyconnect_handler_uartproxy, [tinyconnect_handler_uartproxy:name(),
   %                                    [{subscribe, [uart]},
   %                                     {export_dir, "/tmp/tinyconnect/pty"}] ]}
   % , {tinyconnect_handler_queue,     [?OUTQUEUE,
   %                                    [{subscribe, [{uart,      downstream},
   %                                                  {uartproxy, upstream}]}] ]}
   %],

   %Routes = [],

   %Dispatch = cowboy_router:compile([{'_', Routes}]),

   %Args = [http, 100, [{port, 6999}], [{env, [{dispatch, Dispatch}]}]],

   %{ok, _} = apply(cowboy, start_http, Args),

   supervisor:start_link({local, tinyconnect}, tinyconnect, undefined).

stop(_) -> ok.

init(undefined)   ->
   Sup = #{
        strategy => one_for_one
      , intensity => 5
      , period => 1000
   },

%   ChildPlugins = [
%      #{ id => Mod:name(), start => {Mod, start_link, Args} }
%      || {Mod, Args} <- Plugins],

   % start cloud sync last
   Children = [ #{ id => queue_manager , start => {queue_manager, start_link, []} },
                #{ id => channel_manager , start => {channel_manager, start_link, []} } ],
%              | ChildPlugins ]
%              ++ [ #{ id => cloudsync, start => {cloudsync, start_link, [?OUTQUEUE]}} ],


   { ok, {Sup, Children}}.

main(_) ->
   {ok, _} = application:ensure_all_started(tinyconnect),
   receive stop -> ok end.


emit({Ev, Arg}, Group) ->
   EvID = [atom_to_binary(Group, utf8), atom_to_binary(Ev, utf8)],

   case pg2:get_members(Group) of
      {error, {no_such_group, _}} ->
         ok;

      PIDs ->
         lists:foreach(fun(PID) -> PID ! {'$tinyconnect', EvID, Arg} end, PIDs)
   end;
emit(Ev, Group) when is_atom(Ev) ->
   EvID = [atom_to_binary(Group, utf8), atom_to_binary(Ev, utf8)],

   case pg2:get_members(Group) of
      {error, {no_such_group, _}} ->
         ok;

      PIDs ->
         lists:foreach(fun(PID) -> PID ! {'$tinyconnect', EvID} end, PIDs)
   end.

-module(tinyconnect).
-behaviour(supervisor).
-behaviour(application).

-export([
     init/1
   , start/2
   , stop/1

   , main/1
]).


start(_, _) ->
   Dispatch = cowboy_router:compile([
      {'_', [ {"/ws", tinyconnect_ws, []} ]}
   ]),

   {ok, _} = cowboy:start_http(http
                              , 100
                              , [{port, 8181}]
                              , [{env, [{dispatch, Dispatch}]}]),


   supervisor:start_link({local, tinyconnect}, tinyconnect, undefined).

stop(_) -> ok.

init(undefined)   ->


   Sup = #{
        strategy => one_for_one
      , intensity => 5
      , period => 1000
   },

   Children = [ #{ id => queue_manager ,   start => {queue_manager, start_link, []} },
                #{ id => channel_manager , start => {channel_manager, start_link, []} },
                #{ id => tty_manager,      start => {tty_manager, start_link, []} } ],


   { ok, {Sup, Children}}.

main(_) ->
   {ok, _} = application:ensure_all_started(tinyconnect),
   receive stop -> ok end.

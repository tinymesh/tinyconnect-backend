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

   State = tinyconnect_http:init(),
   Routes = [
        {"/sockjs/[...]", sockjs_cowboy_handler, State},
        {"/",      cowboy_static, {priv_file, tinyconnect, "dist/index.html"}},
        {"/[...]", cowboy_static, {priv_dir, tinyconnect, "dist"}}
   ],

   Dispatch = cowboy_router:compile([{'_', Routes}]),

   Args = [http, 100, [{port, 6999}], [{env, [{dispatch, Dispatch}]}]],

   {ok, _} = apply(cowboy, start_http, Args),

   supervisor:start_link({local, tinyconnect}, tinyconnect, []).

stop(_) -> ok.

init([])   ->
   { ok, {#{
           strategy => one_for_one
         , intensity => 5
         , period => 1000
      }, [

      #{ id => queue_manager
       , start => {queue_manager, start_link, []}
      },

      #{ id => tinyconnect_tty_sup
       , start => {tinyconnect_tty_sup, start_link, []}
      },

      #{ id => tinyconnect_tty_ports
       , start => {tinyconnect_tty_ports, start_link, []}
       , type  => worker
      }

   ]}}.

main(_) ->
   application:ensure_all_started(tinyconnect),
   receive stop -> ok end.


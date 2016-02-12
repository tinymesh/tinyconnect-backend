-module(tinyconnect).
-behaviour(supervisor).
-behaviour(application).

-export([
     init/1
   , start/2
   , stop/1
]).

start(_, _) ->

   State = tinyconnect_http:init(),
   Routes = [ {"/sockjs/[...]", sockjs_cowboy_handler, State, []} ],

   Dispatch = cowboy_router:compile([{'_', Routes}]),

   {ok, _} = cowboy:start_http(http, 100, [{port, 6999}], [{env, [{dispatch, Dispatch}]}]),

   supervisor:start_link({local, tinyconnect}, tinyconnect, []).

stop(_) -> ok.

init([])   ->
   { ok, {#{
           strategy => one_for_one
         , intensity => 5
         , period => 1000
      }, [

      #{ id => tinyconnect_tty_sup
       , start => {tinyconnect_tty_sup, start_link, []}
       , type  => supervisor
      }

   ]}}.

-module(tinyconnect_handler).

-export([
   init/1
]).

init(Path) ->
    sockjs_handler:init_state(Path, fun handle/3, #{}, []).

handle(Conn, E, State) ->
   io:format("ev: ~p~n", [E]),
   {ok, State}.

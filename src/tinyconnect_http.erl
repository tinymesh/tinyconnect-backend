-module(tinyconnect_http).

-export([
     init/0
]).

init() ->
   sockjs_handler:init_state(<<"/sockjs">>, fun handle/3, #{}, []).

handle(Conn, Ev, State) ->
   'Elixir.Logger':log(info, io_lib:format("~p", [Ev])),
   {ok, State}.

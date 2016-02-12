-module(tinyconnect_tty_sup).
-behaviour(supervisor).

-export([
     start_link/0

   , init/1
   , start_port/1
]).

start_link() ->
   supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init(_Args) ->
   ChildSpec = #{
        id => nil
      , start => {tinyconnect_tty, start_link, []}
      , type => worker
      , restart => transient
   },
   { ok, {#{ strategy => simple_one_for_one }, [ChildSpec]}}.

start_port(Port) ->
   Id = binary_to_atom(Port, utf8),
   supervisor:start_child(?MODULE,  #{
      id => Id,
      start => {tinyconnect_tty, start_link, [Port]}
   }).

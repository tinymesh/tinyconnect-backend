-module(tinyconnect_tty_sup).
-behaviour(supervisor).

-export([
     start_link/0

   , init/1
   , start_port/1
   , stop_port/1
]).

start_link() ->
   supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init(_Args) ->
   { ok, {#{ strategy => one_for_one }, []}}.

start_port(Path) ->
   ChildSpec = #{
        id => binary_to_atom(Path, utf8)
      , start => {tinyconnect_tty, start_link, [Path]}
      , type => worker
      , restart => transient
   },

   case supervisor:start_child(?MODULE,  ChildSpec) of
		{ok, _} = Res ->
			Res;

		{error, {{bad_return_value, {error, Err}}, _}} ->
			{error, Err}
	end.

stop_port(Path) ->
	Path2 = binary_to_atom(Path, utf8),

	case lists:filter(fun({P, _, _, _}) -> P =:= Path2
		end, supervisor:which_children(?MODULE)) of

		[] ->
			{error, notfound};

		[{ID, undefined, _, _}] ->
			ok = supervisor:delete_child(?MODULE, ID);

		[{ID, Pid, _, _}] ->
			ok = tinyconnect_tty:stop(Pid),
			ok = supervisor:delete_child(?MODULE, ID)
	end.

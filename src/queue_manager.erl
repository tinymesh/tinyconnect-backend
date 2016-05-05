-module(queue_manager).
-behaviour(supervisor).

-export([
     start_link/0
   , init/1

   , ensure/1
   , ensure/2
]).

ensure(Queue) ->
   ensure(Queue, undefined).

ensure(Queue, ForwardTo) ->
   Children = supervisor:which_children(?MODULE),

   case lists:keyfind(Queue, 1, Children) of
      {Queue, ChildPid, _, _} -> {ok, ChildPid};
      false -> start_child(Queue, ForwardTo)
   end.

start_child(Queue, ForwardTo) ->
   Spec = #{
        id => Queue
      , start => {notify_queue, start_link, [Queue, ForwardTo]}
      , type => worker
      , restart => transient
   },

   case supervisor:start_child(?MODULE, Spec) of
      {ok, _} = Res ->
         Res;

      {error, {{bad_return_value, {error, Err}}, _}} ->
         {error, Err}
   end.


start_link() ->
   supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
   {ok, {#{ strategy => one_for_one }, []}}.

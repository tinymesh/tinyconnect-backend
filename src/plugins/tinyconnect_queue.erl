-module(tinyconnect_queue).
-behaviour(gen_server).

-export([
     handle/2 % plugin handler

%   , init/1
%   , handle_call/3
%   , handle_cast/2
%   , handle_info/2
%
%   , terminate/2
%   , code_change/3
]).

handle({start, ChannelName, PluginDef}, _State) ->
   case maps:get(<<"name">>, PluginDef, undefined) of
      undefined -> {error, {args, #{<<"queue">> => <<"required argument">>}}};
      QueueName ->
         QueueName2 = <<ChannelName/binary, "/", QueueName/binary>>,
         {ok, PID} = queue_manager:ensure(QueueName2, undefined),
         {state, PID, maps:put(<<"queue">>, QueueName2, PluginDef)}
   end;

handle(_, nostate) -> ok;

% for every event receive notify next step of entire queue contents
% there's no way to pass any success/failure callbacks to the system
% but next step can send a `done` event that we may listen to
handle({event, input, <<Buf/binary>>, _Meta}, Server) ->
   _ = lager:debug("queue[~p] input: ~p", [Server, Buf]),
   {ok, _Item} = notify_queue:add(Server, Buf),
   {ok, Items} = notify_queue:as_list(Server),
   {emit, queue, Items, Server};

handle({event, forwarded, QueueItems, _Meta}, Server) ->
   ok = notify_queue:without(Server, QueueItems),
   ok.


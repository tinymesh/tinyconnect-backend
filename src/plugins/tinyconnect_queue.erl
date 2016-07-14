-module(tinyconnect_queue).
-behaviour(gen_server).

% manages forwarding queues, these queues are used for ensuring data
% will not be lost in case of crashes.
% serial ports, then identifying - and possibly reconfiguring - each
% Tinymesh capable device

-export([
     name/1
   , stop/1

   , start_link/2
   , init/1
   , handle_call/3
   , handle_cast/2
   , handle_info/2
   , terminate/2
   , code_change/3
]).

-export_type([def/0]).

-type channel() :: tinyconnect_channel:channel().
-type queue() :: atom().

-type def() :: #{
   queue => queue(),
   accept => function(),
   % what sources to subscribe to events from
   subscribe => [channel() | {channel(), [PlugName :: binary()]}],
   % the module to handle tty connections
   % name of plugin
   name => Name :: binary(),
   % opts for gen_server
   opts => Opts :: term(),
   start_after => [],
   backoff => {TimerRef :: reference() | undefined, undefined | backoff:backoff()}
}.

default(Chan) ->
   #{
      queue => binary_to_atom(Chan, utf8),
      accept => fun(_, _) -> true end,
      subscribe   => [{Chan, ["uart"]}]
    }.

%% plugin api

-spec name(pid()) -> {ok, Name :: binary()}.
name(Server) -> gen_server:call(Server, name).

-spec stop(pid()) -> ok.
stop(Server) -> gen_server:call(Server, stop).


%%%% gen_server implementation
%%%
-spec start_link(Chan :: channel(), def()) -> {ok, pid()} | {error, term()}.
start_link(Chan, PluginDef) ->
   Plugin = maps:merge(default(Chan), PluginDef),
   gen_server:start_link(?MODULE, [Chan, Plugin], []).

init([Chan, #{queue := Queue, name := Name} = Plugin]) ->
   {ok, _Queue} = queue_manager:ensure(Queue, undefined),
   ok = tinyconnect_channel:subscribe([Chan, Name], Plugin),
   ok = tinyconnect_channel:emit([Chan, Name], Plugin, open, #{pid => self()}),

   {ok, Plugin}.

handle_call(stop, _From, State) -> {stop, normal, ok, State};
handle_call(name, _From, #{name := Name} = State) -> {reply, {ok, Name}, State}.

handle_cast(nil, State) -> {noreply, State}.

handle_info({'$tinyconnect', Resource, #{data := _} = Ev},
            #{accept := Accept, queue := Queue, channel := Chan, name := Name} = State) ->

   case (acceptfun(Accept))(Resource, Ev) of
      true ->
         #{data := Frame} = Ev,
         {ok, _} = notify_queue:add(Queue, Frame, maps:get(at, Ev, erlang:timestamp())),
         tinyconnect_channel:emit([Chan, Name], State, update, #{queue => Queue}),
         {noreply, State};

      false ->
         {noreply, State}
   end;
handle_info({'$tinyconnect', _, #{} = _Ev} , State) ->
   {noreply, State}.

terminate(_Reason, _State) -> ok.

code_change(_OldVsn, _NewVsn, State) -> {ok, State}.

acceptfun({Mod, Fun}) -> fun Mod:Fun/2;
acceptfun(Fun) when is_function(Fun, 2) -> Fun.

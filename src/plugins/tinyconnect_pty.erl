-module(tinyconnect_pty).
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

-type def() :: #{
   % the port ref
   port    => port() | undefined,
   % optional symlink file to to link to slave pty
   link => file:filename_all() | undefined,
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
      subscribe   => [{Chan, ["uart"]}],
      link        => undefined,
      port        => undefined
    }.

%% plugin api

-spec name(pid()) -> {ok, Name :: binary()}.
name(Server) -> gen_server:call(Server, name).

-spec stop(pid()) -> ok.
stop(Server) -> gen_server:call(Server, stop).


%%%% gen_server implementation

-spec start_link(Chan :: channel(), def()) -> {ok, pid()} | {error, term()}.
start_link(Chan, PluginDef) ->
   Plugin = maps:merge(default(Chan), PluginDef),
   gen_server:start_link(?MODULE, [Chan, Plugin], []).

init([Chan, #{name := Name} = Plugin]) ->

   ok = tinyconnect_channel:subscribe([Chan, Name], Plugin),

   NewPlugin = open(Plugin),
   ok = tinyconnect_channel:emit([Chan, Name], NewPlugin, open, #{pid => self()}),

   {ok, NewPlugin}.

open(#{} = Plugin) ->
   {[_|_] = Exec, Env} = find_socat(),

   ok = mklinkdir(Plugin),
   Port = erlang:open_port({spawn_executable, Exec}, [
        {env, Env}
      , binary
      , exit_status
      , {args, [maybe_link(<<"PTY,raw">>, Plugin), <<"-">>]}]),

   Plugin#{port => Port}.

mklinkdir(#{link := undefined}) -> ok;
mklinkdir(#{link := Link}) ->
   _ = lists:foldl(fun(Seg, Acc) ->
      case file:make_dir(filename:join(Acc ++ [Seg])) of
         {error, eexist} -> Acc ++ [Seg];
         ok -> Acc ++ [Seg]
      end
   end, [], filename:split(filename:dirname(Link))),
   ok.

maybe_link(Arg, #{link := undefined}) -> Arg;
maybe_link(Arg, #{link := Link}) -> <<Arg/binary, ",link=", Link/binary>>.

find_socat() ->
   case os:getenv("TINYCONNECT_BINDIR") of
      false -> {os:find_executable("socat"), []};
      Path -> {filename:join(Path, "socat"), [{"LD_LIBRARY_PATH", Path}]}
   end.

handle_call(stop, _From, State) -> {stop, normal, ok, State};
handle_call(name, _From, #{name := Name} = State) -> {reply, {ok, Name}, State}.

handle_cast(nil, State) -> {noreply, State}.

handle_info({'$tinyconnect', _Res, #{type := data, data := Data}},
            #{port := Port} = State) ->
   erlang:port_command(Port, Data),
   {noreply, State};
handle_info({'$tinyconnect', _, #{} = _Ev}, State) ->
   {noreply, State};

handle_info({Port, {data, Buf}}, #{channel := Chan, name := Name, port := Port} = State) ->
   ok = tinyconnect_channel:emit([Chan, Name], State, data, #{data => Buf}),
   {noreply, State};
handle_info({Port, {exit_status, _} = E}, #{port := Port} = State) ->
   {stop, E, State}.

terminate(_Reason, _State) -> ok.

code_change(_OldVsn, _NewVsn, State) -> {ok, State}.


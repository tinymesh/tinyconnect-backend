-module(tinyconnect_handler_uartproxy).
-behaviour(gen_server).

% Creates a pseudo terminal using the external program `socat`.
% This allows programs already speaking over a serialport to
% work as normally while still utilizing other handlers.

-export([
     name/0
   , stop/0, stop/1

   , start_link/1, start_link/2
   , init/1
   , handle_call/3
   , handle_cast/2
   , handle_info/2
   , terminate/2
   , code_change/3
]).

-type opt() :: {subscribe, [RegName :: atom()]}
             | {export_dir, [file:filename_all()]}.
-type opts() :: [opt()].

-define(SERVER, 'uartproxy').

name() -> ?SERVER.

stop() -> stop(?SERVER).
stop(Server) -> gen_server:call(Server, stop).

-spec start_link(RegName :: atom(), opts()) -> {ok, pid()} | {error, term()}.
start_link(Name) -> start_link(Name, []).
start_link(Name, Opts) ->
   gen_server:start_link({local, Name}, ?MODULE, [Name, Opts], []).

init([Name, Opts]) ->
   ok = subscribe(lists:keyfind(subscribe, 1, Opts)),
   {ok, Exports} = exports(lists:keyfind(export_dir, 1, Opts)),

   {ok, #{exports => Exports, name => Name, ports => []}}.

subscribe(false) -> ok;
subscribe({subscribe, []}) -> ok;
subscribe({subscribe, [Group | Groups]}) ->
   ok = pg2:create(Group),
   ok = pg2:join(Group, self()),
   subscribe({subscribe, Groups}).

exports(false) -> {error, {export_dir, not_set}};
exports({export_dir, ExportDir}) ->
   {ok, Dir}    = mkdir_p(filename:split(ExportDir)),
   {ok, _ByID}  = mkdir_p(filename:split(filename:join(Dir, <<"by-id">>))),
   {ok, _ByNID} = mkdir_p(filename:split(filename:join(Dir, <<"by-nid">>))),
   {ok, Dir}.

mkdir_p(Parts) -> mkdir_p(Parts, <<>>).
mkdir_p([], FullPath) -> {ok, FullPath};
mkdir_p([H|T], Path) ->
   case file:make_dir(NextPath = filename:join(Path, H)) of
      ok -> mkdir_p(T, NextPath);
      {error, eexist} -> mkdir_p(T, NextPath);
      Res -> Res
   end.

handle_call(stop, _From, State) ->  {stop, normal, ok, State};
handle_call({open, _NID}, _From, State) ->  {reply, uartproxy_open_not_implemented,     State};
handle_call({close, _NID}, _From, State) -> {reply, uartproxy_close_not_implemented,    State}.

handle_cast(nil, State) ->
   {noreply, State}.

handle_info({'$tinyconnect', [_, <<"open">>]  = Ev, Args}, State) -> {noreply, open(Ev, Args, State)};
handle_info({'$tinyconnect', [_, <<"close">>] = Ev, Args}, State) -> {noreply, close(Ev, Args, State)};
handle_info({'$tinyconnect', [_, <<"data">>]  = Ev, Args}, State) -> {noreply, data(Ev, Args, State)};
handle_info({'$tinyconnect', [_, <<"added">>],   _Args}, State) -> {noreply, State};
handle_info({'$tinyconnect', [_, <<"removed">>], _Args}, State) -> {noreply, State};

handle_info({Port, {data, Buf}}, #{ports := Ports, name := Name} = State) ->
   case lists:keyfind(Port, 2, Ports) of
      {ID, Port} ->
         Arg = #{data => Buf, id => ID, name => Name, mod => ?MODULE, type => uartproxy},
         tinyconnect:emit({data, Arg}, Name),
         {noreply, State};

      false ->
         {noreply, State}
   end.

terminate(_Reason, _State) -> ok.

code_change(_OldVsn, _NewVsn, State) -> {ok, State}.



% $tinyconnect events


open([_Who, <<"open">>], #{id := ID, type := uart}, #{exports := Exports,
                                                      name := Name,
                                                      ports := Ports} = State) ->

   [_|_] = Exec = os:find_executable("socat"),
   % Links /dev/vtty0 -> {exports}/by-id/vtty0 -> /dev/pts/<N>
   Link = filename:join([Exports, <<"by-id">>, ID]),

   Port = erlang:open_port({spawn_executable, Exec}, [
        {env, []} % LD_LIBRARY_PATH=???
      , binary
      , exit_status
      , {args, [<<"PTY,link=", Link/binary, ",raw">>, <<"-">>]}
      , stderr_to_stdout]),

   Arg = #{id => ID, mod => ?MODULE, name => Name, type => name(), paths => [Link]},
   tinyconnect:emit({open, Arg}, Name),

   State#{ports => [{ID, Port} | Ports]}.

close([_Who, <<"close">>], #{id := ID, type := uart}, #{ports := Ports} = State) ->
   case lists:keyfind(ID, 1, Ports) of
      {ID, Port} ->
         true = erlang:port_close(Port),
         State#{ports => lists:keydelete(ID, 1, Ports)};

      false ->
         State
   end.

data([_Who, <<"data">>], #{id := ID, data := Buf}, #{ports := Ports} = State) ->
   case lists:keyfind(ID, 1, Ports) of
      {ID, Port} ->
         true = erlang:port_command(Port, Buf),
         State;

      false ->
         State
   end.

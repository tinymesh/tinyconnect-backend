-module(tinyconnect_handler_http).
-behaviour(gen_server).

-export([
     name/0

   , open/1,  open/2
   , close/1, close/2

   , start_link/0, start_link/1
   , init/1
   , handle_call/3
   , handle_cast/2
   , handle_info/2
   , terminate/2
   , code_change/3
]).

-define(SERVER, 'http-handler').

%% handler abstract
name() -> ?SERVER.

open(NID)  -> open(NID, ?SERVER).
open(NID, Server)  -> gen_server:call(Server, {open, NID}).

close(NID) -> close(NID, ?SERVER).
close(NID, Server) -> gen_server:call(Server, {close, NID}).


%% gen_server implementation

start_link() -> gen_server:start_link({local, name()}, ?MODULE, [name()], []).
start_link(Name) -> gen_server:start_link({local, Name}, ?MODULE, [Name], []).

init([Name]) ->
   ok = pg2:create(Name),
   {ok, #{}}.

handle_call(stop, _From, State) -> {stop, normal, ok, State}.

handle_cast(nil, State) -> {noreply, State}.

handle_info(nil, State) -> {noreply, State}.

terminate(_Reason, _State) -> ok.

code_change(_OldVsn, _NewVsn, State) -> {ok, State}.

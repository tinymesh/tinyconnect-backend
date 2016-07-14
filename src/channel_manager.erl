-module(channel_manager).
-behaviour(supervisor).

%% CHANNEL STATE MANAGER
%%
%% Keeps a list channels available and what their up to.
%%
%% A channel is defined as _SOME_ handler (uart,cloudsync...) that may
%% be connected to other channels (uart -> uartproxy ...).
%%
%% There is two methods of discovering channels:
%%  - implicit UART: using `tinyconnect.search_path` a set of serial
%%    ports may be provided.
%%  - explicit config: using `{channels, [#{} = ChanDef]}`.
%%
%% Both methods are continuously scanned and additions/removals are
%% applied on the fly.
%%
%% The channel configuration takes the following form:
%%
%%  - `channel` -> channel()
%%  - `autoconnect` -> true | false | always (`always` kills channel %%  if not available)
%%  - `plugins#uart` -> uartdef()
%%  - `plugins#cloudsync` -> cloudsyncdef()
%%  - `plugins#uartproxy` -> cloudsyncdef()
%%

-export([
     start_link/0, start_link/1
   , init/1


   , reload/0, reload/1

   , child/1, child/2
   , channels/0, channels/1

   , add/1, add/2
   , remove/1, remove/2
   , connect/1, connect/2
   , disconnect/1, disconnect/2
]).

-type channel() :: tiynconnect_channel:channel().
-type def() :: tiynconnect_channel:def().

-define(SUP, ?MODULE).
-define(DEFCHAN, #{
   autoconnect => false,
   plugins => [],
   source => user
}).

start_link() -> start_link(?SUP).
start_link(Sup) ->
   supervisor:start_link({local, Sup}, ?MODULE, []).

init([]) ->
   {ok, Cfg} = load(),
   {channels, Channels} = lists:keyfind(channels, 1, Cfg),
   Children = lists:map(fun(#{channel := Chan} = Def) ->
      #{
         id => Chan,
         start => {tinyconnect_channel, start_link, [Def]},
         type => worker,
         restart => transient,
         shutdown => brutal_kill
      }
   end, Channels),

   {ok, {#{ strategy => one_for_one }, Children}}.

-spec reload() -> ok | {error, Reason}
   when Reason :: file:posix()
                | badarg
                | terminated
                | system_limit
                | {Line :: integer(), Mod :: module, Term :: term()}.

load() ->
   File = application:get_env(tinyconnect, config_path, "/etc/tinyconnect.cfg"),
   file:consult(File).

reload() -> reload(?SUP).
reload(_Sup) ->
   case load() of
      {ok, _Config} ->
         ok;
      {error, _} = Err -> Err
   end.

-spec channels() -> {ok, [def()|def()] | []}.
channels() -> channels(?SUP).
channels(Sup) ->
   Children = lists:flatmap(fun map_channel/1, supervisor:which_children(Sup)),
   {ok, Children}.

map_channel({_Channel, PID, worker, [Mod]}) ->
   {ok, Def} = Mod:get(PID),
   [Def].

-spec add(def()) -> ok | {error, term()}.
add(OrgDef) -> add(OrgDef, ?SUP).
add(#{channel := ChanName} = OrgDef, Sup) ->
   Def = maps:merge(?DEFCHAN, OrgDef),
   case supervisor:start_child(Sup, #{
         id => ChanName,
         start => {tinyconnect_channel, start_link, [Def]},
         type => worker,
         restart => transient,
         shutdown => brutal_kill
      }) of

      {ok, _Pid} -> ok;
      {error, _} = Err -> Err
   end;

add(#{}, _Sup) -> {error, {noarg, channel}}.


-spec remove(Chan :: channel()) -> ok | {error, Reason}
   when Reason :: not_found
                | restarting
                | running
                | simple_one_for_one
                | {notfound, {channel, channel()}}.
remove(Chan) -> remove(Chan, ?SUP).
remove(Chan, Sup) ->
   case child(Chan, Sup) of
      {ok, {PID, Mod}} ->
         ok = Mod:stop(PID),
         ok = supervisor:terminate_child(Sup, Chan),
         supervisor:delete_child(Sup, Chan);

      {error, _} = Err ->
         Err
   end.
% ensures all plugins are running
-spec connect(Chan :: channel()) -> ok | {error, term()}.
connect(Chan) -> connect(Chan, ?SUP).
connect(_Chan, _Sup) -> ok.


% ensures all plugins are stopped
-spec disconnect(Chan :: channel()) -> ok | {error, term}.
disconnect(Chan) -> disconnect(Chan, ?SUP).
disconnect(_Chan, _Sup) -> ok.


-spec child(Chan) -> {ok, {pid(), module()}}
                   | {error, {notfound, {channel, Chan}}}
                   when Chan :: channel().
child(Chan) -> child(Chan, ?SUP).
child(Chan, Sup) ->
   case lists:keyfind(Chan, 1, supervisor:which_children(Sup)) of
      {Chan, PID, worker, [Mod]} -> {ok, {PID, Mod}};
      false -> {error, {notfound, {channel, Chan}}}
   end.

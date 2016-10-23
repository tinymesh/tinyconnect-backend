-module(tty_manager).
-behaviour(gen_server).

-export([
     start_link/0

   , subscribe/0
   , subscribe/1
   , unsubscribe/0
   , unsubscribe/1

   , get/0
   , get/1

   , refresh/0

   , init/1
   , handle_call/3
   , handle_cast/2
   , handle_info/2
   , terminate/2
   , code_change/3

   , listports/1
]).

-define(group, ports).

subscribe() -> subscribe(self()).
subscribe(PID) -> ok = pg2:join(?group, PID).

unsubscribe() -> unsubscribe(self()).
unsubscribe(_PID) -> ok. %ok = pg2:leave(?group, PID).

get() -> gen_server:call(?MODULE, get).
get(ID) when is_binary(ID) -> gen_server:call(?MODULE, {get, ID}).

refresh() ->
   gen_server:call(?MODULE, refresh).

start_link() ->
   gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init(_) ->
   ok = pg2:create(?group),
   _ = timer:send_interval(1500, refresh),
   {ok, []}.

handle_call(get, _From, State) -> {reply, {ok, State}, State};
handle_call({get, ID}, _From, State) ->
   case lists:filter(
      fun(#{id := Match}) when Match =:= ID -> true;
         (_Item) -> false end, State) of

      [Item] -> {reply, {ok, Item}, State};
      [] -> {reply, {error, notfound}, State}
   end;

handle_call({update, PortID, Patch}, _From, State) when is_binary(PortID) ->
   handle_call({update, binary_to_atom(PortID, utf8), Patch}, _From, State);
handle_call({update, PortID, Patch}, _From, State) ->
   NewState = lists:map(
      fun(#{id := Match} = Item) when Match =:= PortID ->
            maps:merge(Item, Patch);
         (Item) -> Item
      end, State),

   notify(NewState),

   {reply, ok, NewState};

handle_call(refresh, _From, OldPorts) ->
   {ok, Ports} = listports(OldPorts),

   case Ports of
      OldPorts ->
         {reply, {ok, OldPorts}, OldPorts};

      NewPorts ->
         io:format("ports: new ports (total: ~p)~n", [length(NewPorts)]),
         notify(NewPorts),
         {reply, {ok, NewPorts}, NewPorts}
   end;

handle_call(_, _From, State) -> {noreply, State}.

handle_cast(_, State) -> {noreply, State}.

handle_info(refresh, OldPorts) ->
   {ok, Ports} = listports(OldPorts),

   case Ports of
      OldPorts ->
         {noreply, Ports};

      NewPorts ->
         io:format("ports: new ports (total: ~p)~n", [length(NewPorts)]),
         notify(NewPorts),
         {noreply, NewPorts}
   end.

terminate(_Reason, _State) -> ok.

code_change(_OldVsn, _NewVsn, State) -> {ok, State}.

portstruct(Path) when is_list(Path) -> portstruct(iolist_to_binary(Path));
portstruct(Path) -> portstruct(filename:basename(Path), Path, filename:basename(Path)).
portstruct(ID, Path, Name) when is_list(ID)   -> portstruct(iolist_to_binary(ID), Path, Name);
portstruct(ID, Path, Name) when is_list(Path) -> portstruct(ID, iolist_to_binary(Path), Name);
portstruct(ID, Path, Name) when is_list(Name) -> portstruct(ID, Path, iolist_to_binary(Name));
portstruct(ID, Path, Name) ->
   #{
        id   => ID
      , path => Path
      , name => Name
      , 'proto/tm' => #{nid => nil, sid => nil, uid => 0}
   }.

notify(NewPorts) ->
   Members = pg2:get_members(?group),
   lists:foreach(fun(PID) -> PID ! {?MODULE, ports, NewPorts} end, Members).

listports(Ports) ->
   case os:type() of
      {unix, linux} ->
         NewPorts = lists:map(
            fun(Path) ->
               #{id := ID} = Default = portstruct(Path),

               case lists:filter(fun(#{id := M}) -> ID =:= M end, Ports) of
                  [] -> Default;
                  [E] -> E
               end
            end, filelib:wildcard("/dev/serial/by-id/*")),
         {ok, NewPorts};

      {win32, nt} ->
         Buf = iolist_to_binary(os:cmd("wmic path Win32_PnPEntity WHERE \"Name LIKE '%USB Serial Port%'\" GET DeviceID,Name")),
         case binary:split(Buf, [<<"\n">>, <<"\r">>], [global, trim_all]) of
            [] -> {ok, []};
            [_Head] -> {ok, []};
            [Head | Rest] ->
               Keys = re:split(Head, "[ ]{2,}", [trim]),
               Res = lists:map(fun(Line) ->
                  Vals = re:split(Line, "[ ]{2,}", [trim]),
                  #{<<"Name">> := Name} = maps:from_list(lists:zip(Keys, Vals)),
                  [_, ID] = binary:split(Name, [<<"(">>, <<")">>], [global, trim]),

                  Default = portstruct(ID, ID, Name),

                  case lists:filter(fun(#{id := M}) -> ID =:= M end, Ports) of
                     [] -> Default;
                     [E] -> E
                  end
               end, Rest),

               {ok, Res}
         end
   end.

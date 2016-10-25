-module(tty_manager).
-behaviour(gen_server).

-export([
     start_link/1
   , start_link/2

   , subscribe/0 , subscribe/1 , subscribe/2
   , unsubscribe/0 , unsubscribe/1 , unsubscribe/2

   , get/1, get/2

   , refresh/0, refresh/1

   , init/1
   , handle_call/3
   , handle_cast/2
   , handle_info/2
   , terminate/2
   , code_change/3

   , listports/1
]).

subscribe() -> subscribe(?MODULE).
subscribe(Server) -> subscribe(self(), Server).
subscribe(PID, Server) -> gen_server:call(Server, {subscribe, PID}).

unsubscribe() -> unsubscribe(?MODULE).
unsubscribe(Server) -> unsubscribe(self(), Server).
unsubscribe(PID, Server) -> gen_server:call(Server, {unsubscribe, PID}).

get(Server) -> gen_server:call(Server, get).
get(ID, Server) when is_binary(ID) -> gen_server:call(Server, {get, ID}).

refresh() -> refresh(?MODULE).

refresh(Server) ->
   gen_server:call(Server, refresh).

start_link(GroupName) -> gen_server:start_link(?MODULE, [GroupName], []).
start_link(GroupName, RegName) -> gen_server:start_link(RegName, ?MODULE, [GroupName], []).

init(GroupName) ->
   _ = pg2:create(PG2Group = {tty_manager, GroupName}),
   _ = timer:send_interval(1500, refresh),
   {ok, #{pg2 => PG2Group, ports => []}}.

handle_call(get, _From, #{ports := Ports} = State) -> {reply, {ok, Ports}, State};
handle_call({get, ID}, _From, #{ports := Ports} = State) ->
   case lists:filter(
      fun(#{<<"id">> := Match}) when Match =:= ID -> true;
         (_Item) -> false end, Ports) of

      [Item] -> {reply, {ok, Item}, State};
      [] -> {reply, {error, notfound}, State}
   end;

handle_call({update, PortID, Patch}, _From, State) when is_binary(PortID) ->
   handle_call({update, binary_to_atom(PortID, utf8), Patch}, _From, State);
handle_call({update, PortID, Patch}, _From, #{ports := Ports} = State) ->
   NewPorts = lists:map(
      fun(#{<<"id">> := Match} = Item) when Match =:= PortID ->
            maps:merge(Item, Patch);
         (Item) -> Item
      end, Ports),

   notify(State#{ports => NewPorts}),

   {reply, ok, State#{ports => NewPorts}};

handle_call(refresh, _From, #{ports := OldPorts} = State) ->
   {ok, Ports} = listports(OldPorts),

   case Ports of
      OldPorts ->
         {reply, {ok, OldPorts}, State};

      NewPorts ->
         lager:info("tty_manager: ports changed, total: ~p", [length(NewPorts)]),
         notify(State#{ports => NewPorts}),
         {reply, {ok, NewPorts}, State#{ports => NewPorts}}
   end;

handle_call({subscribe, Who}, _From, #{pg2 := PG2} = State) ->
   lager:debug("tty_manager: add subscription ~p", [Who]),
   {reply, pg2:join(PG2, Who), State};

handle_call({unsubscribe, Who}, _From, #{pg2 := PG2} = State) ->
   lager:debug("tty_manager: rem subscription ~p", [Who]),
   {reply, pg2:leave(PG2, Who), State};

handle_call(_, _From, State) -> {noreply, State}.

handle_cast(_, State) -> {noreply, State}.

handle_info(refresh, #{ports := OldPorts} = State) ->
   {ok, Ports} = listports(OldPorts),

   case Ports of
      OldPorts ->
         {noreply, State};

      NewPorts ->
         io:format("ports: new ports (total: ~p)~n", [length(NewPorts)]),
         notify(State#{ports => NewPorts}),
         {noreply, State#{ports => NewPorts}}
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
        <<"id">>   => ID
      , <<"path">> => Path
      , <<"name">> => Name
      , <<"proto/tm">> => #{<<"nid">> => null, <<"sid">> => null, <<"uid">> => null}
   }.

notify(#{ports := NewPorts, pg2 := PG2}) ->
   Members = pg2:get_members(PG2),
   lager:debug("tty_manager: notify ~p", [Members]),
   lists:foreach(fun(PID) -> PID ! {?MODULE, ports, NewPorts} end, Members).

listports(Ports) ->
   case application:get_env(tinyconnect, test_ttys, os:type()) of
      {test, NewPorts} ->
         {ok, lists:map(fun portstruct/1, NewPorts)};

      {unix, linux} ->
         NewPorts = lists:map(
            fun(Path) ->
               #{<<"id">> := ID} = Default = portstruct(Path),

               case lists:filter(fun(#{<<"id">> := M}) -> ID =:= M end, Ports) of
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

                  case lists:filter(fun(#{<<"id">> := M}) -> ID =:= M end, Ports) of
                     [] -> Default;
                     [E] -> E
                  end
               end, Rest),

               {ok, Res}
         end
   end.

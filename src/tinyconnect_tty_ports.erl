-module(tinyconnect_tty_ports).
-behaviour(gen_server).

-export([
     start_link/0

   , get/0
   , get/1
   , update/2

   , init/1
   , handle_call/3
   , handle_cast/2
   , handle_info/2
   , terminate/2
   , code_change/3

   , listports/1
]).

get() -> gen_server:call(?MODULE, get).
get(ID) -> gen_server:call(?MODULE, {get, ID}).

update(ID, Patch) -> gen_server:call(?MODULE, {update, ID, Patch}).

-define(group, ports).

start_link() ->
   gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init(_) ->
   ok = pg2:create(?group),
   timer:send_interval(1500, refresh),
   {ok, []}.

handle_call(get, _From, State) -> {reply, {ok, State}, State};
handle_call({get, ID}, _From, State) when is_binary(ID) ->
   handle_call({get, binary_to_atom(ID, utf8)}, _From, State);
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

   case NewState =/= State of
      true  -> updated(NewState);
      false -> ok
   end,

   {reply, ok, NewState};

handle_call(_, _From, State) -> {noreply, State}.

handle_cast(_, State) -> {noreply, State}.

handle_info(refresh, OldPorts) ->
   {ok, Ports} = listports(OldPorts),

   case Ports of
      OldPorts ->
         {noreply, Ports};

      NewPorts ->
         io:format("ports: new ports (total: ~p)~n", [length(NewPorts)]),

         updated(NewPorts),
         {noreply, NewPorts}
   end.

updated(NewPorts) ->
   lists:foreach(fun(E) -> E ! {ports, NewPorts} end, pg2:get_members(?group)).

terminate(_Reason, _State) -> ok.

code_change(_OldVsn, _NewVsn, State) -> {ok, State}.

listports(Ports) ->
   case os:type() of
      {unix, linux} ->
         NewPorts = lists:map(
            fun(Path) ->
               Default = #{
                    id   => ID = list_to_atom(filename:basename(Path))
                  , path => list_to_binary(Path)
                  , name => list_to_binary(Path)
                  , conn => false
                  , uart => false
                  , nid  => nil
                  , sid  => nil
                  , uid  => nil
               },

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
                  ID2 = binary_to_atom(ID, utf8),

                  Default = #{
                       id => ID2
                     , path => ID
                     , name => Name
                     , uart => false
                     , conn => false
                     , nid  => nil
                     , sid  => nil
                     , uid  => nil
                  },

                  case lists:filter(fun(#{id := M}) -> ID2 =:= M end, Ports) of
                     [] -> Default;
                     [E] -> E
                  end
               end, Rest),

               {ok, Res}
         end
   end.

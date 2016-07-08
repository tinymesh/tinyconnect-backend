-module(tinyconnect_handler_queue).
-behaviour(gen_server).

-export([
     name/0

   , open/1
   , close/1

   , start_link/1, start_link/2
   , init/1
   , handle_call/3
   , handle_cast/2
   , handle_info/2
   , terminate/2
   , code_change/3
]).


-type opt() :: {subscribe, [RegName :: atom()]}.
-type opts() :: [opt()].

-define(SERVER, 'tmcloud').

name() -> ?SERVER.

open(NID)  ->
   gen_server:call({local, ?SERVER}, {open, NID}).

close(NID) ->
   gen_server:call({local, ?SERVER}, {close, NID}).


-spec start_link(RegName :: atom(), opts()) -> {ok, pid()} | {error, term()}.
start_link(Name) -> start_link(Name, []).
start_link(Name, Opts) ->
   gen_server:start_link({local, Name}, ?MODULE, [Name, Opts], []).

init([Name, Opts]) ->
   Queue = binary_to_atom(<<"queue#", (atom_to_binary(Name, utf8))/binary>>, utf8),
   {ok, _Queue} = queue_manager:ensure(Queue, undefined),

   Subscriptions = proplists:get_value(subscribe, Opts),
   ok = subscribe(Subscriptions),
   ChanTags = lists:foldl(fun({K, V}, Acc) -> maps:put(K, V, Acc);
                           (_, Acc) -> Acc end, #{}, Subscriptions),

   {ok, #{name => Name,
          queue => Queue,
          chantags => ChanTags, % maps `ev#{type}` -> contexs
          ctxs => #{}           % maps of different input partials
   }}.

subscribe([]) -> ok;
subscribe([{Group, _} | Groups]) ->
   subscribe([Group | Groups]);
subscribe([Group | Groups]) ->
   ok = pg2:create(Group),
   ok = pg2:join(Group, self()),
   subscribe(Groups).

handle_call({open, _NID}, _From, State) ->  {reply, tmcloud_open_not_implemented,     State};
handle_call({close, _NID}, _From, State) -> {reply, tmcloud_close_not_implemented,    State}.

handle_cast(nil, State) ->
   {noreply, State}.

handle_info({'$tinyconnect', [_, <<"open">>],  _Args}, State) -> {noreply, State};
handle_info({'$tinyconnect', [_, <<"close">>], _Args}, State) -> {noreply, State};
handle_info({'$tinyconnect', [_, <<"data">>]  = Ev, Args}, State) -> {noreply, data(Ev, Args, State)};
handle_info({'$tinyconnect', [_, <<"added">>],   _Args}, State) -> {noreply, State};
handle_info({'$tinyconnect', [_, <<"removed">>], _Args}, State) -> {noreply, State}.

%handle_info({'$notify_queue', {update, ?QUEUE}}, State) -> {noreply, State}.
%   {ok, {_N, _Buf} = E} = notify_queue:peek(?QUEUE),
%   ok = notify_queue:pop(?QUEUE, E),
%   {noreply, State}.

data(_Ev,
     #{data := Buf, type := Chan, id := ID},
     #{chantags := ChanTags,
       ctxs := Ctxs,
       queue := Queue,
       name := Name} = State) ->

   Ctx = case ChanTags of
      #{Chan := ContextName} -> ContextName;
      _ -> default end,

   case deframe([{erlang:timestamp(), Buf} | maps:get(Ctx, Ctxs, [])]) of
      {ok, {When, Frame}, Rest} ->
         {ok, _} = notify_queue:add(Queue, Frame, When),

         % maybe, or in this case definitely, ack...
         tinyconnect:emit({data,
                           #{data => <<6>>, id => ID, mod => ?MODULE, type => name()}},
                          Name),

         State#{ctxs => maps:put(Ctx, Rest, Ctxs)};

      false ->
         Next = [{erlang:timestamp(), Buf} | maps:get(Ctx, Ctxs, [])],
         State#{ctxs => maps:put(Ctx, Next, Ctxs)}
   end.

deframe(Input) ->
   deframe(lists:reverse(Input), {undefined, undefined, <<>>}).

deframe([{_, <<Len, _/binary>>} | Rest], {undefined, undefined, <<>>} = Acc)
   when Len > 138; (Len < 18 andalso Len =/= 10) ->

   deframe(Rest, Acc);

deframe([{When, Buf} | Rest], {undefined, undefined, <<>>}) ->
   deframe(Rest, {When, When, Buf});

deframe(Fragments, {When, Last, <<Len, _/binary>> = Acc})
   when byte_size(Acc) >= Len ->

   case Acc of
      <<Buf:(Len)/binary>> ->
         {ok, {When, Buf}, lists:reverse(Fragments)};

      <<Buf:(Len)/binary, Next/binary>> ->
         {ok, {When, Buf}, lists:reverse([{Last, Next} | Fragments])}
   end;

deframe([{Last, Buf} | Rest], {When, _Last, Acc}) ->
   deframe(Rest, {When, Last, <<Acc/binary, Buf/binary>>});

deframe([], _Acc) -> false.

terminate(_Reason, _State) -> ok.

code_change(_OldVsn, _NewVsn, State) -> {ok, State}.

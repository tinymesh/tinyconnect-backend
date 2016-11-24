-module(notify_queue).
-behaviour(gen_server).

-export([
     start_link/2

   , add/2, add/3
   , pop/2
   , peek/1
   , clear/1
   , forward/2
   , as_list/1
   , shift/2
   , without/2

   , init/1
   , handle_call/3
   , handle_cast/2
   , handle_info/2
   , terminate/2
   , code_change/3
]).

-export_type([queue/0]).

% Provides a forwarding queue for proxying events between upstream and
% downstream connections. One adds to the queue, the queue notifies
% the subscriber

-type data() :: binary().
-type item() :: {binary(), data()}.
-type queue() :: atom().


utc_datetime(TS = {_, _, Micro}) ->
    {{Year, Month, Day}, {Hour, Minute, Second}} = calendar:now_to_universal_time(TS),
    iolist_to_binary(io_lib:format("~4w-~2..0w-~2..0wT~2w:~2..0w:~2..0w.~6..0wZ",
		  [Year,Month,Day,Hour,Minute,Second,Micro])).

-spec add(queue(), data()) -> ok.
add(Queue, Data) -> add(Queue, Data, erlang:timestamp()).
add(Queue, Data, When) ->
   gen_server:call(Queue, {add, utc_datetime(When), Data}).

-spec pop(queue(), item()) -> ok | error.
pop(Queue, {_, _} = Data) ->
   gen_server:call(Queue, {pop, Data}).

-spec peek(queue()) -> {ok, item()} | empty.
peek(Queue) ->
   gen_server:call(Queue, peek).

-spec clear(queue()) -> ok.
clear(Queue) ->
   gen_server:call(Queue, clear).

-spec forward(queue(), pid()) -> ok.
forward(Queue, ForwardTo) ->
   gen_server:call(Queue, {forward, ForwardTo}).

-spec as_list(queue()) -> {ok, [item()]}.
as_list(Queue) ->
   gen_server:call(Queue, as_list).

-spec shift(queue(), non_neg_integer()) -> ok.
shift(Queue, N) ->
   gen_server:call(Queue, {shift, N}).

-spec without(queue(), [item()]) -> ok.
without(Queue, Items) ->
   gen_server:call(Queue, {without, Items}).

-spec start_link( queue(), pid() ) -> {ok, pid()}.
start_link(Queue, ForwardTo) ->
   gen_server:start_link(?MODULE, [Queue, ForwardTo], []).

init([Queue, ForwardTo]) ->
   {ok, #{queue => queue:new(),
          name => Queue,
          forwarding => ForwardTo}}.

handle_call({add, Now, Buf}, _From, #{queue := Queue, forwarding := ForwardTo} = State) ->
   NewQueue = queue:in({Now, Buf}, Queue),

   Pid = if
      is_pid(ForwardTo)  -> ForwardTo;
      is_atom(ForwardTo) -> queue_manager:lookup(ForwardTo)
   end,

   _ = case Pid of
      false -> nil;
      Pid when is_pid(Pid) -> Pid ! {'$notify_queue', {update, maps:get(name, State)}}
   end,

   {reply, {ok, {Now, Buf}}, State#{queue := NewQueue}};

handle_call({without, Items}, _From, #{queue := Queue} = State) ->
   NewQueue = queue:filter(fun(Item) -> not lists:member(Item, Items) end, Queue),
   {reply, ok, State#{queue => NewQueue}};

handle_call(peek, _From, #{queue := Queue} = State) ->
   case queue:peek(Queue) of
      {value, Val} -> {reply, {ok, Val}, State};
      empty -> {reply, {error, empty}, State}
   end;

handle_call({pop, {_T, _V} = Val}, _From, #{queue := Queue} = State) ->
   case queue:peek(Queue) of
      {value, Val} -> {reply, ok, State#{ queue := queue:tail(Queue) }};
      {value, _Other} -> {reply, error, State};
      empty -> {reply, ok, State}
   end;

handle_call({forward, ForwardTo}, _From, State) ->
   {reply, ok, State#{forwarding => ForwardTo}};

handle_call(as_list, _From, #{queue := Queue} = State) ->
   Items = queue:to_list(Queue),
   {reply, {ok, Items}, State};

handle_call({shift, N}, _From, #{queue := Queue} = State) ->
   {_, NewQueue} = queue:split(N, Queue),
   {reply, ok, State#{queue => NewQueue}};

handle_call(clear, _From, State) ->
   {reply, ok, State#{queue := queue:new()}}.

handle_cast(nil, State) -> {noreply, State}.

handle_info(nil, State) -> {noreply, State}.

terminate(_Reason, _State) -> ok.

code_change(_OldVsn, _NewVsn, State) -> {ok, State}.

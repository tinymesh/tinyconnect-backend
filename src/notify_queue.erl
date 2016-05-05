-module(notify_queue).
-behaviour(gen_server).

-export([
     start_link/2

   , add/2
   , pop/2
   , peek/1
   , clear/1
   , forward/2

   , init/1
   , handle_call/3
   , handle_cast/2
   , handle_info/2
   , terminate/2
   , code_change/3
]).

% Provides a forwarding queue for proxying events between upstream and
% downstream connections. One adds to the queue, the queue notifies
% the subscriber

-type data() :: binary().
-type item() :: {binary(), data()}.
-type queue() :: atom().


-spec add(queue(), data()) -> ok.
add(Queue, Data) ->
   Now = 'Elixir.Timex.DateTime':now(),
   NowFmt = 'Elixir.Timex':'format!'(Now, <<"{ISO:Extended}">>),
   gen_server:call(Queue, {add, NowFmt, Data}).

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

-spec start_link( queue(), pid() ) -> {ok, pid()}.
start_link(Queue, ForwardTo) ->
   case whereis(Queue) of
      Pid when is_pid(Pid) ->
         Alive = is_process_alive(Pid),
         if
            Alive ->
               link(Pid),
               {ok, Pid};

            true ->
               gen_server:start_link({local, Queue}, ?MODULE, [Queue, ForwardTo], [])
         end;

      undefined ->
         gen_server:start_link({local, Queue}, ?MODULE, [Queue, ForwardTo], [])
   end.

init([Queue, ForwardTo]) ->
   {ok, #{queue => queue:new(),
          name => Queue,
          forwarding => ForwardTo}}.

handle_call({add, Now, Buf}, _From, #{queue := Queue, forwarding := ForwardTo} = State) ->
   NewQueue = queue:in({Now, Buf}, Queue),

   Pid = if
      is_pid(ForwardTo) -> ForwardTo;
      is_atom(ForwardTo) -> whereis(ForwardTo)
   end,

   case Pid of
      undefined -> nil;
      Pid -> Pid ! {update, maps:get(name, State)}
   end,

   {reply, {ok, {Now, Buf}}, State#{queue := NewQueue}};

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


handle_call(clear, _From, State) ->
   {reply, ok, State#{queue := queue:new()}}.

handle_cast(nil, State) -> {noreply, State}.

handle_info(nil, State) -> {noreply, State}.

terminate(_Reason, _State) -> ok.

code_change(_OldVsn, _NewVsn, State) -> {ok, State}.

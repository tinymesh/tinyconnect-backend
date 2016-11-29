-module(tmtestutil).

-export([
     forward/2
   , collect/2
]).

% Some stuff used for testing...

forward({event, input, X, _Meta}, State) -> {emit, input, X, State};
forward(_, _State) -> ok.

collect({event, T, X, _Meta}, _State) -> {state, {T, X}};
collect(serialize, State) -> {ok, State};
collect({start, _, _}, _State) -> {ok, nil}.

-module(tinyconnect_ws).
-behaviour(cowboy_http_handler).
-behaviour(cowboy_websocket_handler).
-export([init/3, handle/2, terminate/3]).
-export([
    websocket_init/3, websocket_handle/3,
    websocket_info/3, websocket_terminate/3
]).

init({tcp, http}, _Req, _Opts) ->
  _ = random:seed(erlang:system_time()),
  {upgrade, protocol, cowboy_websocket}.


handle(Req, State) ->
   _ = lager:error("request not expected: ~p~", [Req]),
   {ok, Req2} = cowboy_http_req:reply(404, [{'Content-Type', <<"text/html">>}]),
   {ok, Req2, State}.


websocket_init(_TransportName, Req, _Opts) ->
   tty_manager:subscribe(),
   {ok, Req, undefined_state}.

websocket_handle({text, Msg}, Req, State) ->
   parse_ref(binary:split(Msg, <<" ">>), fun(Return) -> {reply, {text, Return}, Req, State, hibernate} end);

websocket_handle(_Any, Req, State) ->
    Ret = {error, <<"unknown input...">>},
    {reply, {text, encode(<<"null">>, Ret)}, Req, State, hibernate }.

websocket_info({timeout, _Ref, Msg}, Req, State) ->
    {reply, {text, Msg}, Req, State};

websocket_info(_Info, Req, State) ->
    error_logger:info_msg("websocket info"),
    {ok, Req, State, hibernate}.

websocket_terminate(_Reason, _Req, _State) ->
   tty_manager:unsubscribe(),
    ok.

terminate(_Reason, _Req, _State) ->
    ok.

parse_ref([Ref, Rest], Ret) ->
   case binary:split(Rest, <<"{">>) of
      [Req, Data] ->
         parse_json(Req, <<"{", Data/binary>>, fun(Return) -> Ret(encode(Ref, Return)) end);

      [Req] ->
         parse_json(Req, <<"{}">>, fun(Return) -> Ret(encode(Ref, Return)) end)
   end;
parse_ref(_, Ret) ->
   Ret(encode(<<"null">>, {error, <<"invalid data">>})).

parse_json(Req, Data, Ret) ->
   case (catch jsx:decode(Data, [return_maps])) of
      {'EXIT', _} ->
         Ret({error, <<"failed to decode json request">>});

      #{} = Map ->
         case binary:split(Req, <<" ">>, [global, trim_all]) of
            [<<"channels">> | Args] -> channels(Args, Map, Ret);

            [<<"serialports">> | Args] -> serialports(Args, Map, Ret);

            [<<"plugins">> | Args] -> plugins(Args, Map, Ret);

            _ -> Ret({error, <<"invalid command, try one of `channels`, `serialports`">>})
         end;

      _ ->
         Ret(<<"invalid format: use `channels|serialports [opts ...] <data>">>)
   end.

channels([<<"list">>], _Args, Ret) ->
   {ok, Channels} = channel_manager:channels(),
   Ret({ok, #{channels => sanitize_channels(Channels)}});

% Channel start/stop:
%
% Channels have no `state` as such, starting and stopping a channel refers to
% starting or stopping the plugins of a channel.
%
% Starts (aka connects) a channel
channels([<<"start", _Chan/binary>>], _Args, Ret) ->
   {ok, Channels} = channel_manager:channels(),
   Ret({ok, #{channels => sanitize_channels(Channels)}});

% Stops (aka disconnect) a already running channel
channels([<<"stop",  _Chan/binary>>], _Args, Ret) ->
   {ok, Channels} = channel_manager:channels(),
   Ret({ok, #{channels => sanitize_channels(Channels)}});

% create a new channel
channels([<<"new">>], Args, Ret)  ->
   K = uuid:uuid(),

   Args2 = maps:put(<<"channel">>, maps:get(<<"channel">>, Args, K), Args),
   case channel_manager:add(Args2) of
      ok ->
         {ok, Channels} = channel_manager:channels(),
         Ret({ok, #{channels => Channels, newchannel => K}});

      {error, Err} ->
         error_logger:error_msg("failed to create channel ~s:~n\t~p~n", [K, Err]),
         Ret({error, iolist_to_binary(io_lib:format("~p", [Err]))})
   end;

channels([<<"update">>, Chan], Args, Ret) ->
   try
      case channel_manager:update(Chan, Args) of
         {ok, _} ->
            {ok, Channels} = channel_manager:channels(),
            Ret({ok, #{channels => Channels}});

         {error, _} = E ->
            Ret(E)
      end
   catch throw:{key_error, K} -> Ret({error, #{<<"invalidkey">> => K}}) end;

channels([<<"remove">>, Chan], _Args, Ret) ->
   case channel_manager:remove(Chan) of
      ok ->
        {ok, Channels} = channel_manager:channels(),
         Ret({ok, #{channels => sanitize_channels(Channels)}});

      {error, not_found}                   -> Ret({error, #{<<"error">> => <<"notfound">>}});
      {error, restarting}                  -> Ret({error, #{<<"error">> => <<"restarting">>}});
      {error, running}                     -> Ret({error, #{<<"error">> => <<"running">>}});
      {error, simple_one_for_one}          -> Ret({error, #{<<"error">> => <<"simple_one_for_one">>}});
      {error, {notfound, {channel, Chan}}} -> Ret({error, #{<<"error">> => <<"notfound">>, <<"channel">> => Chan}})
   end;

channels(_, _, Ret) -> Ret({error, <<"invalid command, try one `channels list ",
                                     "| new ",
                                     "| update <chan> ",
                                     "| start <chan> ",
                                     "| stop <chan> ",
                                     "| remove <chan> ",
                                     "`">>}).

serialports([<<"scan">>], _Args, Ret) ->
   {ok, Ports} = tty_manager:refresh(),
   Ret({ok, #{serialports => Ports}});
serialports([<<"list">>], _Args, Ret) ->
   {ok, Ports} = tty_manager:get(),
   Ret({ok, #{serialports => Ports}});
serialports(_, _Args, Ret) ->
   Ret({error, <<"invalid command, try one `serialports scan|list`">>}).

plugins([<<"list">>], _Args, Ret) ->
   Ret({ok, #{plugins => []}});
plugins([<<"defaults">>, _Chan], _Args, Ret) ->
   Ret({ok, #{plugins => []}});
plugins(_, _Args, Ret) ->
   Ret({error, <<"invalid command, try one `plugins list`">>}).






encode_plugin(Plugin) -> maps:fold(fun(K, V, Acc) ->
      case plugin_mapper(K, V) of
         undefined -> Acc;
         NewV -> maps:put(K, NewV, Acc)
      end
   end, #{}, Plugin).

plugin_mapper(recvbackoff, _V) -> undefined;
plugin_mapper(sendbackoff, _V) -> undefined;
plugin_mapper(backoff, _V) -> undefined;
plugin_mapper(rest, _V) -> undefined;
plugin_mapper(port, _V) -> undefined;
plugin_mapper(accept, {M,F}) -> <<(atom_to_binary(M, utf8))/binary, "/", (atom_to_binary(F, utf8))/binary>>;
plugin_mapper(accept, _F) -> <<"anonymous-function">>;
plugin_mapper(identity, {N, S, U}) -> #{nid => plugin_mapper({identity, nid}, N),
                                        sid => plugin_mapper({identity, sid}, S),
                                        uid => plugin_mapper({identity, uid}, U)};
plugin_mapper(subscribe, S) ->
   lists:foldl(fun({Chan, Plugins}, Acc) ->
      maps:put(Chan, Plugins, Acc)
   end, #{}, S);
plugin_mapper(queues, Queues) -> Queues;
plugin_mapper(_K, undefined) -> undefined;
plugin_mapper(_K, V) when is_binary(V) -> V;
plugin_mapper(_K, V) when is_atom(V) -> atom_to_binary(V, utf8);
plugin_mapper(_K, V) -> iolist_to_binary(io_lib:format("~p", [V])).



sanitize_channels(Chans) -> sanitize_channels(Chans, []).
sanitize_channels([], Acc) -> lists:reverse(Acc);
sanitize_channels([#{plugins := Plugins} = Chan | Rest], Acc) ->
   Chan2 = Chan#{plugins => sanitize_plugins(Plugins)},
   sanitize_channels(Rest, [Chan2 | Acc]).

sanitize_plugins(Plugins) -> sanitize_plugins(Plugins, []).
sanitize_plugins([], Acc) -> lists:reverse(Acc);
sanitize_plugins([Plug | Rest], Acc) ->
   sanitize_plugins(Rest, [encode_plugin(Plug) | Acc]).



encode(Ref, {error, <<Err/binary>>}) -> <<Ref/binary, " ", (jsx:encode(#{error => Err}))/binary>>;
encode(Ref, {error, Err}) -> <<Ref/binary, " ", (jsx:encode(#{error => Err}))/binary>>;
encode(Ref, {ok, Resp}) ->
   try
      Enc = jsx:encode(#{resp => Resp}),
      <<Ref/binary, " ", (Enc)/binary>>
   catch
      _:_ ->
         error_logger:error_msg("failed to encode json:~n\t~p~n", [Resp]),
         <<Ref/binary, " {\"error\": \"failed to encode response json....\"}">>
   end.

% API:
%
% - `channels list` - lists all channels
% - `channels start <chan>` - start `chan`
% - `channels stop <chan>` - stop `chan`
%
% - `serialport scan` - scan for serialports
% - `serialport list` - list of serial ports

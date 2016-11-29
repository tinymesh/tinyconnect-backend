-module(tinyconnect_mqtt).
-behaviour(gen_server).

-export([
        handle/2

      , init/1
      , handle_call/3
      , handle_cast/2
      , handle_info/2

      , terminate/2
      , code_change/3
]).

handle({start, ChannelName, #{<<"opts">> := _Options} = PluginDef}, _State) ->
   gen_server:start_link(?MODULE, [ChannelName, PluginDef], []);

handle({event, Type, <<Buf/binary>>, _Meta}, State) when is_pid(State) ->
   State ! {emit, Type, Buf},
   ok.

init([Channel, #{<<"opts">> := Options,
                 <<"id">> := ID} = Def]) ->
   {ok, MQTT} = emqttc:start_link(Options),
   %%
   %% The pending subscribe
   Subscriptions = maps:get(<<"subscribe">>, Def, []),
   Publishers = maps:get(<<"publish">>, Def, []),
   lists:foreach( fun(Topic) -> ok = emqttc:subscribe(MQTT, Topic, 1) end, Subscriptions),
   {ok, #{
      channel => {Channel, ID},
      mqttc => MQTT,
      seq => 1,
      publish => Publishers,
      topics => Subscriptions
   }}.

handle_call(stop, _From, State) ->
    {stop, normal, ok, State};

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

%% Publish Messages
handle_info({emit, _Type, Payload}, State = #{mqttc := C, seq := I, publish := Topics}) ->
   lists:foreach( fun(Topic) ->
      lager:info("mqtt: publish ~p, ~p", [Topic, Payload]),
      ok = emqttc:publish(C, Topic, Payload, [])
   end, Topics),
   lager:info("mqtt: published!!!"),
   {noreply, State#{seq => I+1}};

%% Receive Messages
handle_info({publish, _Topic, Payload}, State = #{channel := {Channel, PlugID}}) ->
    lager:info("mqtt: received data! ~p ->->->-> ~p", [_Topic, Payload]),
    ok = tinyconnect_channel2:emit({global, Channel}, PlugID, input, Payload),
    {noreply, State};

%% Client connected
handle_info({mqttc, C, connected}, State = #{topic := Topic, mqttc := C}) ->
    lager:info("Client ~p is connected~n", [C]),
    ok = emqttc:subscribe(C, Topic, 1),
    {noreply, State};

%% Client disconnected
handle_info({mqttc, C,  disconnected}, State = #{mqttc := C}) ->
    lager:warn("Client ~p is disconnected~n", [C]),
    {noreply, State};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

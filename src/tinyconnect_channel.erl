-module(tinyconnect_channel).

-export_type([
     channel/0
   , extplugin/0
   , intplugin/0
   , extdef/0
]).

-type channel() :: binary().

-type extplugin() :: #{}.
-type intplugin() :: {Handler :: term(), State :: term(), PlugDef :: extplugin()}.

-type extdef() :: #{
%   <<"channel">>     => channel(),
%   <<"autoconnect">> => true | false,
%   <<"plugins">>     => [extplugin()],
%   <<"source">>      => user | config
}.

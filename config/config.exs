use Mix.Config

config :tinyconnect, :config_path, nil
config :tinyconnect, :rescan_interval, 5000

config :lager, :handlers, [lager_console_backend: :debug]

import_config "#{Mix.env}.exs"

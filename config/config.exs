use Mix.Config

config :tinyconnect, :config_path, nil
config :tinyconnect, :rescan_interval, 5000

import_config "#{Mix.env}.exs"

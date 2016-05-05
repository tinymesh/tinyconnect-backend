use Mix.Config

config :tinyconnect,
  remote: "https://http.cloud.tiny-mesh.com/v2",
  networks: %{}

import_config "#{Mix.env}.exs"

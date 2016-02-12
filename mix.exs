defmodule Tinyconnect.Mixfile do
  use Mix.Project

  @version "0.3.0-alpha"
  def project do
    [app: :tinyconnect,
     version: @version,
     elixir: "~> 1.0",
     elixirc_paths: ["lib"],
     deps: deps
    ]
  end

  def application do
    [mod: {:tinyconnect, []},
     applications: [
      :logger,
      :cowboy,
      :sockjs
     ]
    ]
  end

  defp deps do
    [
      {:cowboy, "~> 1.0.4", override: true},
      {:sockjs, github: "ably-forks/sockjs-erlang"},
      {:gen_serial, github: "tomszilagyi/gen_serial", tag: "v0.2", compile: "make", app: false},
    ]
  end
end

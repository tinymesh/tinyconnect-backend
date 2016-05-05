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
      :crypto,
      :public_key,
      :ssl,
      :hackney,

      :cowboy,
      :poison,
      :sockjs,
      :crypto,

      :timex
     ],
     env: [
       remote: 'tcp.cloud-ng.tiny-mesh.com',
     ]
    ]
  end

  defp deps do
    [
      {:cowboy, "~> 1.0.4", override: true},
      {:poison, "~> 2.0.1"},
      {:sockjs, github: "ably-forks/sockjs-erlang"},
      {:gen_serial, github: "tomszilagyi/gen_serial", tag: "v0.2", compile: "make", app: false},

      {:hackney, "~> 1.6"},
      {:timex, "~> 2.1"}
    ]
  end
end

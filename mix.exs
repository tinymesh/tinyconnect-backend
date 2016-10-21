defmodule Tinyconnect.Mixfile do
  use Mix.Project

  @version "0.4.0-alpha"
  def project do
    [app: :tinyconnect,
     version: @version,
     language: :erlang,
     deps: deps,
     dialyzer: dialyzer
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
      :crypto,

      :backoff,

      :jsx,
      :gen_serial,
      :tinymesh
     ],
     env: []
    ]
  end

  defp deps do
    [
      {:cowboy, "~> 1.0.4", override: true},
      {:jsx, "~> 2.8"},
      {:hackney, "~> 1.6"},
      {:tinymesh, github: "tinymesh/tm-proto-erlang"},
      {:backoff, "~> 1.1", manager: :rebar3},

      # dev, since they need native compilaa
      {:gen_serial, github: "lafka/gen_serial", branch: "lafka-add-makefile", compile: "make", app: false},
      {:procket, github: "msantos/procket", tag: "0.7.0"},

      # test
      {:mock, "~> 0.1.3", only: :test},   # mock some libraries
      {:socket, "~> 0.3.5", only: :test}, # used for websocket tests

      # actual dev
      {:dialyxir, "~> 0.3.5", only: [:dev]}

    ]
  end

  defp dialyzer do
    [
      plt_add_deps: :transitive
    ]
  end
end

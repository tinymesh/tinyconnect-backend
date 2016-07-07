defmodule Tinyconnect.Mixfile do
  use Mix.Project

  @version "0.3.0-alpha"
  def project do
    [app: :tinyconnect,
     version: @version,
     language: :erlang,
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
      :crypto,

      :jsx,
      :gen_serial,
      :tinymesh
     ],
     env: [
       remote: 'tcp.cloud-ng.tiny-mesh.com',
     ]
    ]
  end

  defp deps do
    [
      {:cowboy, "~> 1.0.4", override: true},
      {:jsx, "~> 2.8"},
      {:gen_serial, github: "lafka/gen_serial", branch: "lafka-add-makefile", compile: "make", app: false},
      {:hackney, "~> 1.6"},
      {:tinymesh, github: "tinymesh/tm-proto-erlang"},
      {:mock, "~> 0.1.3", only: :test}
    ]
  end
end

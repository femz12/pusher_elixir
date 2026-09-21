defmodule PusherServer.MixProject do
  use Mix.Project

  @source_url "https://github.com/YOUR_GH_USERNAME/pusher_server"
  @version "0.1.0"

  def project do
    [
      app: :pusher_server,
      version: @version,
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: [
        pusher_server: [
          include_executables_for: [:unix]
        ]
      ],

      # --- Hex package metadata (fill in before `mix hex.publish`) ---
      description: "A self-hosted, Pusher-protocol-compatible WebSocket server " <>
                   "(drop-in for Laravel Reverb) built on Cowboy.",
      package: package(),
      docs: docs(),
      source_url: @source_url
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto, :inets, :ssl],
      mod: {PusherServer.Application, []}
    ]
  end

  defp deps do
    [
      {:plug, "~> 1.16"},
      {:plug_cowboy, "~> 2.7"},
      {:jason, "~> 1.4"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib mix.exs README.md LICENSE CHANGELOG.md)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CHANGELOG.md"]
    ]
  end
end

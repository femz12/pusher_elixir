defmodule PusherServer.Application do
  @moduledoc """
  OTP application callback — only relevant when this project is compiled
  and released as its own standalone deployment (the Docker image). When
  `pusher_server` is instead pulled in as a hex dependency of another
  app, this starts an empty supervisor and does nothing: the host app is
  expected to add `{PusherServer, opts}` to its own supervision tree
  explicitly (see PusherServer's moduledoc).

  The distinction is made via `config :pusher_server, :standalone?`,
  which is set to `true` only in this project's own config/runtime.exs.
  A dependency's config/runtime.exs is not evaluated when building
  someone else's release, so this stays `false` (the safe default) for
  anyone who adds this as a dependency.
  """
  use Application
  require Logger

  def start(_type, _args) do
    children =
      if Application.get_env(:pusher_server, :standalone?, false) do
        [{PusherServer, name: PusherServer}]
      else
        []
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: PusherServer.RootSupervisor)
  end

  @doc """
  Called by OTP when the application is stopping (e.g. on SIGTERM during
  `docker stop` / a rolling deploy of the standalone release). Drains
  connections instead of just letting every socket die mid-flight.
  """
  def stop(_state) do
    if Application.get_env(:pusher_server, :standalone?, false) do
      PusherServer.drain(PusherServer)
      # brief window so clients can receive the close frame and start
      # reconnecting before the BEAM actually goes down
      Process.sleep(1_000)
    end

    :ok
  end
end

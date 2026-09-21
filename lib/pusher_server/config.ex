defmodule PusherServer.Config do
  @moduledoc """
  Per-instance configuration.

  Resolves explicit options first (passed to `PusherServer.start_link/1`),
  falling back to environment variables for anything omitted — the same
  variables the standalone release reads. This is what lets the exact
  same code run either as a hex dependency embedded in your own
  supervision tree (config passed explicitly) or as a standalone release
  configured purely by env vars, with zero code differences.
  """

  defstruct [:app_key, :app_secret, :app_id, :port, :webhook_url, :client_messages_enabled]

  @doc "Resolves and caches config for `name` from `opts` + env var fallbacks."
  def resolve(name, opts) do
    config = %__MODULE__{
      app_key: Keyword.get(opts, :app_key) || System.get_env("PUSHER_APP_KEY", "app-key"),
      app_secret: Keyword.get(opts, :app_secret) || System.get_env("PUSHER_APP_SECRET", "app-secret"),
      app_id: Keyword.get(opts, :app_id) || System.get_env("PUSHER_APP_ID", "app-id"),
      port: Keyword.get(opts, :port) || String.to_integer(System.get_env("PORT", "6001")),
      webhook_url: Keyword.get(opts, :webhook_url) || System.get_env("PUSHER_WEBHOOK_URL"),
      client_messages_enabled: Keyword.get(opts, :client_messages_enabled, env_client_messages_enabled?())
    }

    :persistent_term.put({__MODULE__, name}, config)
    config
  end

  defp env_client_messages_enabled? do
    System.get_env("PUSHER_ENABLE_CLIENT_MESSAGES", "true") in ["true", "1"]
  end

  @doc """
  Fetches cached config for `name`, resolving it from env vars on first
  access if it hasn't been explicitly resolved yet (keeps things working
  in contexts like tests that skip PusherServer.start_link/1).
  """
  def get(name) do
    case :persistent_term.get({__MODULE__, name}, nil) do
      nil -> resolve(name, [])
      config -> config
    end
  end

  def valid_app_key?(name, key), do: key == get(name).app_key
  def valid_app_id?(name, id), do: id == get(name).app_id
end

defmodule PusherServer do
  @moduledoc """
  Embed a Pusher-protocol-compatible websocket server in your own
  application's supervision tree:

      children = [
        {PusherServer,
         name: MyApp.PusherServer,
         port: 4001,
         app_key: "my-key",
         app_secret: "my-secret",
         app_id: "my-app-id"}
      ]

  Every option can be omitted; it falls back to the `PUSHER_APP_KEY` /
  `PUSHER_APP_SECRET` / `PUSHER_APP_ID` / `PORT` / `PUSHER_WEBHOOK_URL` /
  `PUSHER_ENABLE_CLIENT_MESSAGES` environment variables (the same ones
  the standalone Docker release reads), so this also works with zero
  config for the common case of one instance per app.

  Running more than one named instance in the same app (e.g. two
  different Pusher app_ids on two different ports) works too — just give
  each a unique `:name`. Each instance gets its own channel registry and
  presence state; they never see each other's connections or channels.
  """
  use Supervisor
  require Logger

  @default_name __MODULE__

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @default_name)
    Supervisor.start_link(__MODULE__, {name, opts}, name: PusherServer.Naming.supervisor(name))
  end

  # use Supervisor's default child_spec/1 keys every child on `id: __MODULE__`,
  # which would collide if a host app mounts two named PusherServer
  # instances under the same supervisor. Key on {module, name} instead.
  def child_spec(opts) do
    name = Keyword.get(opts, :name, @default_name)

    %{
      id: {__MODULE__, name},
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @impl true
  def init({name, opts}) do
    config = PusherServer.Config.resolve(name, opts)
    start_listener(name, config)

    children = [
      {Registry, keys: :duplicate, name: PusherServer.Naming.registry(name)},
      {PusherServer.Presence, name: PusherServer.Naming.presence(name)}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Stops this instance from accepting new connections and tells every
  currently-connected client to reconnect elsewhere (a clean
  `pusher:error` + close frame instead of the socket just dying).

  Call this from your own app's shutdown path if you embed PusherServer;
  the standalone release calls it automatically on SIGTERM.
  """
  def drain(name \\ @default_name) do
    :cowboy.stop_listener(PusherServer.Naming.listener(name))

    Registry.dispatch(PusherServer.Naming.registry(name), :__all_connections__, fn entries ->
      for {pid, _socket_id} <- entries, do: send(pid, :go_away)
    end)

    :ok
  end

  defp start_listener(name, config) do
    dispatch =
      :cowboy_router.compile([
        {:_,
         [
           {"/app/:app_key", PusherServer.WsHandler, %{name: name}},
           {:_, Plug.Cowboy.Handler, {PusherServer.HttpRouter, name: name}}
         ]}
      ])

    {:ok, _} =
      :cowboy.start_clear(
        PusherServer.Naming.listener(name),
        [{:port, config.port}],
        %{env: %{dispatch: dispatch}}
      )

    Logger.info("PusherServer[#{inspect(name)}] listening on port #{config.port}")
  end
end

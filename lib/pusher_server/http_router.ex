defmodule PusherServer.HttpRouter do
  @moduledoc """
  Plug router for the Pusher REST API surface Laravel actually calls:
  POST /apps/{app_id}/events, plus a read-only channel info endpoint.

  Signature verification happens on the raw body/query, before any JSON
  parsing, since the signature covers the exact bytes sent.

  The instance `name` comes in via the plug opts configured in the
  cowboy dispatch table (`{Plug.Cowboy.Handler, {PusherServer.HttpRouter,
  name: name}}`) and is stashed in `conn.private` by overriding `call/2` —
  the standard Plug technique for parameterizing a `Plug.Router`.
  """
  use Plug.Router

  alias PusherServer.{Auth, Config, Naming}

  plug :match
  plug :fetch_query_params
  plug :dispatch

  # `use Plug.Router` builds its own call/2 via Plug.Builder, which marks
  # it `defoverridable` precisely so per-instance data can be injected
  # like this before falling through to the normal match/dispatch pipeline.
  def call(conn, opts) do
    name = Keyword.get(opts, :name, PusherServer)

    conn
    |> Plug.Conn.put_private(:pusher_instance, name)
    |> super(opts)
  end

  get "/" do
    send_resp(conn, 200, "ok")
  end

  post "/apps/:app_id/events" do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    handle_trigger(conn, app_id, body)
  end

  get "/apps/:app_id/channels/:channel" do
    handle_channel_info(conn, app_id, channel)
  end

  match _ do
    send_json(conn, 404, %{error: "not found"})
  end

  defp handle_trigger(conn, app_id, body) do
    name = conn.private.pusher_instance

    with true <- Config.valid_app_id?(name, app_id),
         true <- Auth.valid_request_signature?(name, "POST", conn.request_path, conn.query_params),
         {:ok, %{"name" => event_name, "data" => data} = payload} <- Jason.decode(body) do
      channels = payload["channels"] || List.wrap(payload["channel"])
      exclude_socket_id = payload["socket_id"]
      registry = Naming.registry(name)

      Enum.each(channels, fn channel ->
        encoded = Jason.encode!(%{event: event_name, data: data, channel: channel})

        Registry.dispatch(registry, channel, fn entries ->
          for {pid, _socket_id} <- entries, do: send(pid, {:broadcast, encoded, exclude_socket_id})
        end)
      end)

      send_json(conn, 200, %{})
    else
      false -> send_json(conn, 401, %{error: "invalid signature"})
      {:error, _} -> send_json(conn, 400, %{error: "invalid payload"})
      _ -> send_json(conn, 400, %{error: "bad request"})
    end
  end

  defp handle_channel_info(conn, app_id, channel) do
    name = conn.private.pusher_instance

    with true <- Config.valid_app_id?(name, app_id),
         true <- Auth.valid_request_signature?(name, "GET", conn.request_path, conn.query_params) do
      entries = Registry.lookup(Naming.registry(name), channel)
      occupied = entries != []
      base = %{occupied: occupied, subscription_count: length(entries)}

      info =
        if String.starts_with?(channel, "presence-") do
          Map.put(base, :user_count, length(PusherServer.Presence.members(Naming.presence(name), channel)))
        else
          base
        end

      send_json(conn, 200, info)
    else
      false -> send_json(conn, 401, %{error: "invalid signature"})
    end
  end

  defp send_json(conn, status, payload) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(payload))
  end
end

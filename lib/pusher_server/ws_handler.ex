defmodule PusherServer.WsHandler do
  @moduledoc """
  Implements the client-facing side of the Pusher protocol over a raw
  cowboy websocket (not Phoenix Channels — a different wire format).

  Handles: pusher:subscribe / unsubscribe / ping, private + presence
  channel auth, client events, and broadcasting events pushed in via the
  HTTP trigger endpoint (see PusherServer.HttpRouter).

  Receives the instance `name` via cowboy route opts (see
  `PusherServer.start_listener/2`), so the same handler code serves any
  number of independently-configured instances.
  """
  @behaviour :cowboy_websocket

  alias PusherServer.{Auth, Config, Naming, Presence, Webhook}

  @all_connections :__all_connections__
  @activity_timeout_s 120
  @idle_timeout_ms @activity_timeout_s * 1_000

  # ---- cowboy_websocket callbacks ----

  def init(req, %{name: name}) do
    app_key = :cowboy_req.binding(:app_key, req)

    if Config.valid_app_key?(name, app_key) do
      state = %{name: name, socket_id: nil, channels: MapSet.new()}
      {:cowboy_websocket, req, state, %{idle_timeout: @idle_timeout_ms}}
    else
      req2 = :cowboy_req.reply(4001, req)
      {:ok, req2, %{}}
    end
  end

  def websocket_init(state) do
    socket_id = generate_socket_id()
    # tracked separately from per-channel subscriptions so a graceful
    # shutdown can notify every connected client, subscribed or not
    Registry.register(Naming.registry(state.name), @all_connections, socket_id)

    payload = %{
      event: "pusher:connection_established",
      data: Jason.encode!(%{socket_id: socket_id, activity_timeout: @activity_timeout_s})
    }

    {:reply, {:text, Jason.encode!(payload)}, %{state | socket_id: socket_id}}
  end

  def websocket_handle({:text, msg}, state) do
    case Jason.decode(msg) do
      {:ok, %{"event" => "pusher:subscribe", "data" => data}} ->
        handle_subscribe(data, state)

      {:ok, %{"event" => "pusher:unsubscribe", "data" => %{"channel" => channel}}} ->
        handle_unsubscribe(channel, state)

      {:ok, %{"event" => "pusher:ping"}} ->
        {:reply, {:text, Jason.encode!(%{event: "pusher:pong", data: %{}})}, state}

      {:ok, %{"event" => "client-" <> _rest = event_name, "channel" => channel} = decoded} ->
        handle_client_event(event_name, channel, decoded["data"], state)

      _ ->
        {:ok, state}
    end
  end

  def websocket_handle(_frame, state), do: {:ok, state}

  # Broadcast pushed from the HTTP trigger endpoint via Registry.dispatch
  def websocket_info({:broadcast, message, exclude_socket_id}, state) do
    if state.socket_id == exclude_socket_id do
      {:ok, state}
    else
      {:reply, {:text, message}, state}
    end
  end

  def websocket_info({:broadcast, message}, state) do
    {:reply, {:text, message}, state}
  end

  # Sent by PusherServer.drain/1 during a graceful shutdown so clients get
  # a clean close instead of the TCP connection just dying.
  def websocket_info(:go_away, state) do
    reply = %{
      event: "pusher:error",
      data: %{message: "Server is restarting, please reconnect.", code: 4000}
    }

    {:reply, [{:text, Jason.encode!(reply)}, :close], state}
  end

  def terminate(_reason, _partial_req, state) do
    registry = Naming.registry(state.name)

    Enum.each(Map.get(state, :channels, []), fn channel ->
      # Registry auto-removes this pid's entries once the process actually
      # exits, but that happens after terminate/3 returns — unregister
      # explicitly now so the occupancy check below is accurate.
      Registry.unregister(registry, channel)
      if presence?(channel), do: leave_presence(channel, state.socket_id, state.name)

      if Registry.lookup(registry, channel) == [] do
        Webhook.dispatch(state.name, [%{"name" => "channel_vacated", "channel" => channel}])
      end
    end)

    :ok
  end

  # ---- subscribe/unsubscribe ----

  defp handle_subscribe(%{"channel" => channel} = data, state) do
    auth = data["auth"]
    channel_data = data["channel_data"]

    authorized? =
      if private?(channel) or presence?(channel) do
        Auth.valid_channel_auth?(state.name, state.socket_id, channel, channel_data, auth)
      else
        true
      end

    if authorized? do
      do_subscribe(channel, channel_data, state)
    else
      reply = %{event: "pusher:error", data: %{message: "Invalid signature for channel #{channel}", code: 4009}}
      {:reply, {:text, Jason.encode!(reply)}, state}
    end
  end

  defp handle_subscribe(_data, state), do: {:ok, state}

  # Client events: only allowed on private/presence channels, only from a
  # client actually subscribed to that channel — matches real Pusher's
  # client-event restrictions. Never allowed on public channels.
  defp handle_client_event(event_name, channel, data, state) do
    cond do
      not Config.get(state.name).client_messages_enabled ->
        error_reply("Client events are disabled on this server", state)

      not (private?(channel) or presence?(channel)) ->
        error_reply("Client events are not supported on public channels", state)

      not MapSet.member?(state.channels, channel) ->
        error_reply("Cannot send client event on a channel you're not subscribed to", state)

      true ->
        broadcast_to_channel(
          state.name,
          channel,
          %{event: event_name, channel: channel, data: data},
          state.socket_id
        )

        Webhook.dispatch(state.name, [
          %{
            "name" => "client_event",
            "channel" => channel,
            "event" => event_name,
            "data" => data,
            "socket_id" => state.socket_id
          }
        ])

        {:ok, state}
    end
  end

  defp error_reply(message, state) do
    reply = %{event: "pusher:error", data: %{message: message, code: 4301}}
    {:reply, {:text, Jason.encode!(reply)}, state}
  end

  defp do_subscribe(channel, channel_data, state) do
    registry = Naming.registry(state.name)
    was_unoccupied? = Registry.lookup(registry, channel) == []
    Registry.register(registry, channel, state.socket_id)
    new_channels = MapSet.put(state.channels, channel)

    case build_subscription_data(channel, channel_data, state.name, state.socket_id) do
      {:ok, subscription_data} ->
        if was_unoccupied? do
          Webhook.dispatch(state.name, [%{"name" => "channel_occupied", "channel" => channel}])
        end

        reply = %{
          event: "pusher_internal:subscription_succeeded",
          channel: channel,
          data: Jason.encode!(subscription_data)
        }

        {:reply, {:text, Jason.encode!(reply)}, %{state | channels: new_channels}}

      {:error, message} ->
        # roll back the registration we just made — subscribe failed, so
        # occupancy never actually changed and no webhook should fire
        Registry.unregister(registry, channel)
        reply = %{event: "pusher:error", data: %{message: message, code: 4200}}
        {:reply, {:text, Jason.encode!(reply)}, state}
    end
  end

  defp build_subscription_data(channel, channel_data, name, socket_id) do
    if presence?(channel) do
      case parse_presence_channel_data(channel_data) do
        {:ok, user_id, user_info} ->
          presence_server = Naming.presence(name)
          is_new_member = Presence.add(presence_server, channel, socket_id, user_id, user_info)

          if is_new_member do
            broadcast_to_channel(
              name,
              channel,
              %{
                event: "pusher_internal:member_added",
                channel: channel,
                data: Jason.encode!(%{user_id: user_id, user_info: user_info})
              },
              socket_id
            )

            Webhook.dispatch(name, [%{"name" => "member_added", "channel" => channel, "user_id" => user_id}])
          end

          members = Presence.members(presence_server, channel)

          {:ok,
           %{
             "presence" => %{
               "count" => length(members),
               "ids" => Enum.map(members, fn {uid, _info} -> uid end),
               "hash" => Map.new(members, fn {uid, info} -> {uid, info} end)
             }
           }}

        :error ->
          {:error, "invalid or missing channel_data for presence channel"}
      end
    else
      {:ok, %{}}
    end
  end

  # channel_data is client-controlled input — never trust its shape.
  defp parse_presence_channel_data(channel_data) when is_binary(channel_data) do
    case Jason.decode(channel_data) do
      {:ok, %{"user_id" => user_id} = decoded} when is_binary(user_id) or is_integer(user_id) ->
        {:ok, user_id, decoded["user_info"] || %{}}

      _ ->
        :error
    end
  end

  defp parse_presence_channel_data(_), do: :error

  defp handle_unsubscribe(channel, state) do
    registry = Naming.registry(state.name)
    Registry.unregister_match(registry, channel, state.socket_id)
    if presence?(channel), do: leave_presence(channel, state.socket_id, state.name)

    if Registry.lookup(registry, channel) == [] do
      Webhook.dispatch(state.name, [%{"name" => "channel_vacated", "channel" => channel}])
    end

    {:ok, %{state | channels: MapSet.delete(state.channels, channel)}}
  end

  defp leave_presence(channel, socket_id, name) do
    case Presence.remove(Naming.presence(name), channel, socket_id) do
      {true, user_id} when not is_nil(user_id) ->
        broadcast_to_channel(name, channel, %{
          event: "pusher_internal:member_removed",
          channel: channel,
          data: Jason.encode!(%{user_id: user_id})
        })

        Webhook.dispatch(name, [%{"name" => "member_removed", "channel" => channel, "user_id" => user_id}])

      _ ->
        :ok
    end
  end

  # ---- helpers ----

  defp private?(channel), do: String.starts_with?(channel, "private-")
  defp presence?(channel), do: String.starts_with?(channel, "presence-")

  defp broadcast_to_channel(name, channel, message, exclude_socket_id \\ nil) do
    encoded = Jason.encode!(message)

    Registry.dispatch(Naming.registry(name), channel, fn entries ->
      for {pid, _socket_id} <- entries, do: send(pid, {:broadcast, encoded, exclude_socket_id})
    end)
  end

  defp generate_socket_id do
    "#{:rand.uniform(1_000_000_000)}.#{:rand.uniform(1_000_000_000)}"
  end
end

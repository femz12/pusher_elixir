defmodule PusherServer.Webhook do
  @moduledoc """
  Fires webhooks in the same shape Pusher/Reverb send them, so your
  Laravel app can register a webhook route the way it would for real
  Pusher:

      POST {webhook_url for this instance}
      X-Pusher-Key: <app_key>
      X-Pusher-Signature: HMAC-SHA256(app_secret, raw_body)

      {"time_ms": 1699999999999, "events": [{"name": "channel_occupied", "channel": "..."}]}

  Only fires if the instance has a `webhook_url` configured. Delivery is
  fire-and-forget (a `Task.start/1`) — a slow or dead webhook receiver
  never blocks a websocket connection. Failures are logged, not retried;
  add retry logic here if your use case needs delivery guarantees.
  """
  require Logger
  alias PusherServer.{Auth, Config}

  @doc "Builds the {body, headers} for a webhook payload. Pure — no I/O, easy to test."
  def build(name, events) when is_list(events) do
    config = Config.get(name)
    body = Jason.encode!(%{time_ms: System.system_time(:millisecond), events: events})
    signature = Auth.sign(config.app_secret, body)

    headers = [
      {~c"content-type", ~c"application/json"},
      {~c"x-pusher-key", to_charlist(config.app_key)},
      {~c"x-pusher-signature", to_charlist(signature)}
    ]

    {body, headers}
  end

  @doc "Fire-and-forget dispatch. No-op if this instance has no webhook_url configured."
  def dispatch(name, events) when is_list(events) do
    case Config.get(name).webhook_url do
      nil -> :ok
      url -> Task.start(fn -> send_webhook(name, url, events) end)
    end

    :ok
  end

  defp send_webhook(name, url, events) do
    {body, headers} = build(name, events)

    case :httpc.request(
           :post,
           {to_charlist(url), headers, ~c"application/json", body},
           [{:timeout, 5_000}],
           []
         ) do
      {:ok, {{_version, status, _reason}, _resp_headers, _resp_body}} when status in 200..299 ->
        :ok

      {:ok, {{_version, status, _reason}, _resp_headers, _resp_body}} ->
        Logger.warning("Webhook POST to #{url} returned HTTP #{status}")

      {:error, reason} ->
        Logger.warning("Webhook POST to #{url} failed: #{inspect(reason)}")
    end
  end
end

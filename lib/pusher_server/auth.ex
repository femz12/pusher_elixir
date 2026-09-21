defmodule PusherServer.Auth do
  @moduledoc """
  Implements the two signature schemes Pusher/Reverb use:

  1. Channel auth (private-/presence- subscriptions), signed by Laravel's
     `/broadcasting/auth` route and verified here when a client subscribes.
  2. REST API auth, used by Laravel's server-side `pusher` broadcaster
     when it POSTs an event to `/apps/{app_id}/events`.

  Every function takes an instance `name` first, since different embedded
  instances can have different app credentials.
  """

  def sign(secret, string_to_sign) do
    :crypto.mac(:hmac, :sha256, secret, string_to_sign)
    |> Base.encode16(case: :lower)
  end

  @doc "Verifies the `auth` string a client sends when subscribing to a private/presence channel."
  def valid_channel_auth?(name, socket_id, channel_name, channel_data, provided_auth) do
    config = PusherServer.Config.get(name)

    string_to_sign =
      if channel_data do
        "#{socket_id}:#{channel_name}:#{channel_data}"
      else
        "#{socket_id}:#{channel_name}"
      end

    expected = "#{config.app_key}:#{sign(config.app_secret, string_to_sign)}"
    secure_compare(expected, provided_auth || "")
  end

  @doc """
  Verifies a REST API request's `auth_signature` query param.

  string_to_sign = "METHOD\\nPATH\\nsorted_query_params_excluding_auth_signature"
  """
  def valid_request_signature?(name, method, path, query_params) do
    config = PusherServer.Config.get(name)
    provided = query_params["auth_signature"]

    string_to_sign =
      query_params
      |> Enum.reject(fn {k, _v} -> k == "auth_signature" end)
      |> Enum.sort_by(fn {k, _v} -> k end)
      |> Enum.map_join("&", fn {k, v} -> "#{k}=#{v}" end)
      |> then(&"#{method}\n#{path}\n#{&1}")

    expected = sign(config.app_secret, string_to_sign)
    secure_compare(expected, provided || "")
  end

  # Constant-time comparison to avoid timing attacks on signature checks.
  defp secure_compare(a, b) when is_binary(a) and is_binary(b) do
    if byte_size(a) == byte_size(b) do
      a
      |> :binary.bin_to_list()
      |> Enum.zip(:binary.bin_to_list(b))
      |> Enum.reduce(0, fn {x, y}, acc -> Bitwise.bor(acc, Bitwise.bxor(x, y)) end)
      |> Kernel.==(0)
    else
      false
    end
  end
end

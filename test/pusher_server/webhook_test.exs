defmodule PusherServer.WebhookTest do
  use ExUnit.Case, async: false

  @name :webhook_test_instance

  setup do
    PusherServer.Config.resolve(@name, app_key: "testkey", app_secret: "testsecret", app_id: "testid")
    :ok
  end

  test "build/2 produces a body with the events list and a time_ms field" do
    events = [%{"name" => "channel_occupied", "channel" => "presence-room"}]
    {body, _headers} = PusherServer.Webhook.build(@name, events)

    assert {:ok, decoded} = Jason.decode(body)
    assert decoded["events"] == events
    assert is_integer(decoded["time_ms"])
  end

  test "build/2 signs the body with HMAC-SHA256 over the exact JSON bytes" do
    events = [%{"name" => "member_added", "channel" => "presence-room", "user_id" => "42"}]
    {body, headers} = PusherServer.Webhook.build(@name, events)

    expected_sig = :crypto.mac(:hmac, :sha256, "testsecret", body) |> Base.encode16(case: :lower)

    assert {~c"x-pusher-signature", to_charlist(expected_sig)} in headers
    assert {~c"x-pusher-key", ~c"testkey"} in headers
  end

  test "two different instances sign with their own independent secrets" do
    other_name = :webhook_test_other_instance
    PusherServer.Config.resolve(other_name, app_key: "otherkey", app_secret: "othersecret", app_id: "otherid")

    events = [%{"name" => "channel_occupied", "channel" => "presence-room"}]
    {_body_a, headers_a} = PusherServer.Webhook.build(@name, events)
    {_body_b, headers_b} = PusherServer.Webhook.build(other_name, events)

    refute headers_a == headers_b
  end
end

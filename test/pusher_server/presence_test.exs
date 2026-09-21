defmodule PusherServer.PresenceTest do
  use ExUnit.Case, async: false

  setup do
    name = :"presence_test_#{System.unique_integer([:positive])}"
    {:ok, _pid} = start_supervised({PusherServer.Presence, name: name})
    %{server: name}
  end

  test "first connection for a user_id is reported as a new member", %{server: server} do
    assert PusherServer.Presence.add(server, "presence-room", "sock-a", "user-1", %{}) == true
  end

  test "a second connection (tab) for the same user_id is not a new member", %{server: server} do
    PusherServer.Presence.add(server, "presence-room", "sock-a", "user-1", %{})
    assert PusherServer.Presence.add(server, "presence-room", "sock-b", "user-1", %{}) == false
  end

  test "different users are each reported as new", %{server: server} do
    PusherServer.Presence.add(server, "presence-room", "sock-a", "user-1", %{})
    assert PusherServer.Presence.add(server, "presence-room", "sock-b", "user-2", %{}) == true
  end

  test "removing one of several connections for a user is not the final leave", %{server: server} do
    PusherServer.Presence.add(server, "presence-room", "sock-a", "user-1", %{})
    PusherServer.Presence.add(server, "presence-room", "sock-b", "user-1", %{})

    assert PusherServer.Presence.remove(server, "presence-room", "sock-a") == {false, "user-1"}
  end

  test "removing the last connection for a user is the final leave", %{server: server} do
    PusherServer.Presence.add(server, "presence-room", "sock-a", "user-1", %{})
    assert PusherServer.Presence.remove(server, "presence-room", "sock-a") == {true, "user-1"}
  end

  test "removing an unknown socket_id is a no-op", %{server: server} do
    assert PusherServer.Presence.remove(server, "presence-room", "nope") == {false, nil}
  end

  test "members/2 returns unique users deduped across connections", %{server: server} do
    PusherServer.Presence.add(server, "presence-room", "sock-a", "user-1", %{"name" => "Alice"})
    PusherServer.Presence.add(server, "presence-room", "sock-b", "user-1", %{"name" => "Alice"})
    PusherServer.Presence.add(server, "presence-room", "sock-c", "user-2", %{"name" => "Bob"})

    members = Enum.into(PusherServer.Presence.members(server, "presence-room"), %{})

    assert map_size(members) == 2
    assert members["user-1"] == %{"name" => "Alice"}
    assert members["user-2"] == %{"name" => "Bob"}
  end

  test "channel state is cleared once everyone has left", %{server: server} do
    PusherServer.Presence.add(server, "presence-room", "sock-a", "user-1", %{})
    PusherServer.Presence.remove(server, "presence-room", "sock-a")

    assert PusherServer.Presence.members(server, "presence-room") == []
  end

  test "two different named instances have completely independent state" do
    server_a = :"instance_a_#{System.unique_integer([:positive])}"
    server_b = :"instance_b_#{System.unique_integer([:positive])}"
    start_supervised!({PusherServer.Presence, name: server_a}, id: server_a)
    start_supervised!({PusherServer.Presence, name: server_b}, id: server_b)

    PusherServer.Presence.add(server_a, "presence-room", "sock-a", "user-1", %{})

    assert length(PusherServer.Presence.members(server_a, "presence-room")) == 1
    assert PusherServer.Presence.members(server_b, "presence-room") == []
  end
end

defmodule PusherServer.Naming do
  @moduledoc """
  Derives unique process/registry names from an instance `name`, so
  multiple named instances (e.g. two different app_ids on two different
  ports, both embedded in the same host app) never collide.
  """

  def registry(name), do: Module.concat(name, ChannelRegistry)
  def presence(name), do: Module.concat(name, Presence)
  def listener(name), do: Module.concat(name, Listener)
  def supervisor(name), do: Module.concat(name, Supervisor)
end

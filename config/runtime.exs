import Config

# This file is ONLY evaluated when *this* project is the one being
# compiled into a release (e.g. `mix release` for the standalone Docker
# image). When pusher_server is pulled in as a hex dependency of another
# app, that app's own config/runtime.exs is what runs during its release
# build — this file is never touched, so `standalone?` correctly stays
# `false` (PusherServer.Application's default) for library consumers.
config :pusher_server, standalone?: true

# pusher_server (Elixir)

A minimal, drop-in replacement for Laravel Reverb: an Elixir/Cowboy server
that speaks the Pusher Channels wire protocol, so Laravel's built-in
`pusher` broadcaster works against it unmodified.

Ships two ways from the same code, no forking required:

1. **Standalone** — clone this repo, `docker build`, run it as its own
   container/service (what you'd do to replace Reverb). See "Build & run"
   below.
2. **Embedded** — add it as a hex dependency and mount it directly in
   your own Elixir/Phoenix app's supervision tree, no separate container:

   ```elixir
   # mix.exs
   {:pusher_server, "~> 0.1"}

   # lib/my_app/application.ex
   children = [
     MyApp.Repo,
     MyAppWeb.Endpoint,
     {PusherServer,
      name: MyApp.PusherServer,
      port: 6001,
      app_key: "my-key",
      app_secret: "my-secret",
      app_id: "my-app-id"}
   ]
   ```

   Every option can be omitted and falls back to the same env vars the
   standalone deploy uses. You can even mount more than one named
   instance (different `app_id`s on different ports) — each gets fully
   independent channel/presence state, verified with a real test (see
   `test/pusher_server/presence_test.exs`, "two different named instances
   have completely independent state").

Tested locally (this repo): signature verification, presence join/leave
bookkeeping, webhook payload signing, and multi-instance isolation were
all exercised directly against real HMAC-SHA256 values and confirmed
correct (19 passing tests). Full websocket end-to-end and `mix release`
were **not** compiled/run in the environment this was built in (no access
to hex.pm there) — do a `docker build` + smoke test before relying on it
in production.

## What's implemented

- **Runs standalone (Docker release) or embedded** in another app's
  supervision tree from the same codebase, including multiple
  independently-configured named instances — see "Embedded" above
- WebSocket handshake: `pusher:connection_established`
- `pusher:subscribe` / `pusher:unsubscribe` for public, private, and
  presence channels
- Private/presence channel auth verification (HMAC-SHA256, same scheme
  Pusher/Reverb use)
- Presence channel member tracking, correctly deduped by `user_id` across
  multiple connections (tabs) — `member_added`/`member_removed` only fire
  on first-join / last-leave
- `pusher:ping` / `pusher:pong`
- REST trigger endpoint `POST /apps/{app_id}/events`, with the same
  HMAC-SHA256 request-signing scheme Pusher's HTTP API uses, so Laravel's
  server-side broadcast calls work unmodified
- **Client events** (`client-*`) on private/presence channels — gated on
  the client actually being subscribed, and rejected (matching real
  Pusher behavior) on public channels. Toggle with
  `PUSHER_ENABLE_CLIENT_MESSAGES=false` if you don't want to allow them.
- **Webhooks** — set `PUSHER_WEBHOOK_URL` and the server will POST
  `channel_occupied` / `channel_vacated` / `member_added` /
  `member_removed` / `client_event` to it, signed the same way Pusher
  signs webhooks (`X-Pusher-Key` + `X-Pusher-Signature` headers). Fire-
  and-forget delivery, no retries — add your own if you need guarantees.
- **Read-only channel info**: `GET /apps/{app_id}/channels/{channel}`
  (occupancy + subscriber count, and member count for presence channels),
  signed the same way as the trigger endpoint
- **Idle connection timeout** — cowboy closes a websocket automatically
  after 120s with no client activity (matches the `activity_timeout` the
  server advertises on connect)
- **Graceful shutdown** — on SIGTERM (`docker stop`, a rolling deploy),
  the server stops accepting new connections, sends every connected
  client a clean `pusher:error` + close frame telling it to reconnect
  elsewhere, waits ~1s to let that land, then exits. No connections just
  silently die mid-flight.
- **Hardened against malformed client input** — a client sending garbage
  `channel_data` on a presence-channel subscribe gets a clean
  `pusher:error` reply instead of crashing that connection's process
- **Non-root container user**, a `HEALTHCHECK`, and `--chown` on the
  release copy in the Dockerfile
- Test suite (`test/`) covering the auth signature logic and presence
  join/leave semantics — verified passing against the real modules before
  shipping this

## What's still NOT implemented (add if you need it)

- **Clustering / multi-node**: channel registry and presence state are
  both process-local (in-memory `Registry` + a `GenServer`). Fine for a
  single container, same as running one Reverb instance without its Redis
  scaling adapter. For multiple replicas you'd want to swap these for
  something distributed (e.g. `Phoenix.PubSub` with a PG2/Redis adapter,
  and `Phoenix.Tracker` for presence). Without this, running >1 replica
  behind a load balancer will give you inconsistent presence counts and
  missed broadcasts for clients connected to a different node than the
  one that received the trigger.
- **Batch events** (`POST /apps/{app_id}/batch_events`)
- **Full channel-list endpoint** (`GET /apps/{app_id}/channels`, listing
  *every* active channel) — the single-channel lookup is implemented, but
  listing all of them would need extra state tracking we haven't added
- **Webhook retries** — delivery is fire-and-forget; a webhook receiver
  that's down will just silently miss events
- **Rate limiting** / per-IP connection caps
- **Metrics/observability** — nothing exported for connection counts,
  message throughput, or error rates to alert on
- **TLS termination** — put this behind nginx/Caddy/Traefik/an ALB for
  `wss://`; the app itself only speaks plain HTTP/WS (this is deliberate,
  not an oversight — TLS termination belongs at the proxy layer)

## Before you actually deploy this

1. Run it for real: `docker build`, connect a real Echo client, subscribe
   to a presence channel, trigger an event from Laravel, and pull the
   network cable (or `docker stop`) to confirm the reconnect flow works
2. Put TLS termination in front of it
3. Decide if single-node is acceptable for your traffic, or budget time
   for the clustering work above
4. Add whatever metrics your ops setup expects before it sees real traffic
5. Load-test it (even just a basic websocket load tool) before relying on
   it in production

## Config

Set these env vars (must match your Laravel `.env`):

| Var | Purpose |
|---|---|
| `PUSHER_APP_ID` | must match Laravel's `PUSHER_APP_ID` |
| `PUSHER_APP_KEY` | must match Laravel's `PUSHER_APP_KEY` |
| `PUSHER_APP_SECRET` | must match Laravel's `PUSHER_APP_SECRET` |
| `PORT` | listen port, default `6001` |
| `PUSHER_WEBHOOK_URL` | optional — if set, webhooks POST here |
| `PUSHER_ENABLE_CLIENT_MESSAGES` | optional, default `true` — set `false` to disable client events |

## How standalone vs. embedded actually works

The same `PusherServer.Application` OTP callback runs either way, but it
only auto-starts a listener when `Application.get_env(:pusher_server,
:standalone?, false)` is true. That flag is set in `config/runtime.exs`
— which is **only evaluated when this project itself is the one being
released** (e.g. this repo's own `mix release` for the standalone Docker
image). When another app adds `{:pusher_server, "~> 0.1"}` as a
dependency, *their* `config/runtime.exs` is what runs during *their*
release build, not this one — so the flag stays `false` (the safe
default) and nothing starts automatically. The host app is expected to
explicitly add `{PusherServer, opts}` to its own supervision tree, which
is exactly what makes multiple independently-configured instances
possible in the first place.

This is the actual mechanism that lets one codebase be both a
standalone deployable and a well-behaved embeddable library — worth
understanding if you extend this, since it's easy to accidentally break
by moving that `config :pusher_server, standalone?: true` line into
`config/config.exs` (which *would* get bundled into a dependency's
compiled behavior) instead of `config/runtime.exs`.

## Laravel side

```php
// config/broadcasting.php
'pusher' => [
    'driver' => 'pusher',
    'key' => env('PUSHER_APP_KEY'),
    'secret' => env('PUSHER_APP_SECRET'),
    'app_id' => env('PUSHER_APP_ID'),
    'options' => [
        'host' => env('PUSHER_HOST', '127.0.0.1'),
        'port' => env('PUSHER_PORT', 6001),
        'scheme' => env('PUSHER_SCHEME', 'http'),
        'useTLS' => false,
    ],
],
```

```js
// resources/js/echo.js
new Echo({
    broadcaster: 'pusher',
    key: import.meta.env.VITE_PUSHER_APP_KEY,
    wsHost: import.meta.env.VITE_PUSHER_HOST,
    wsPort: import.meta.env.VITE_PUSHER_PORT,
    forceTLS: false,
    enabledTransports: ['ws'],
});
```

## Build & run

```bash
docker build -t pusher-server .
docker run -p 6001:6001 \
  -e PUSHER_APP_ID=app-id \
  -e PUSHER_APP_KEY=app-key \
  -e PUSHER_APP_SECRET=app-secret \
  pusher-server
```

See `docker-compose.example.yml` for running it alongside your Laravel
app.

## Local dev (without Docker)

```bash
mix deps.get
mix test          # runs test/pusher_server/{auth,presence,webhook}_test.exs
iex -S mix        # config/runtime.exs sets standalone?: true here too,
                  # so this starts the listener on PORT (default 6001)
```

Then connect a websocket client to `ws://localhost:6001/app/app-key` and
POST to `http://localhost:6001/apps/app-id/events` with a properly signed
request to sanity check locally before wiring up Laravel.

## Publishing this to Hex (if you go that route)

Already scaffolded in `mix.exs` (`description`, `package/0`, `docs/0`) and
`LICENSE`/`CHANGELOG.md` — fill in the placeholder GitHub URL and license
holder name first. Then, roughly:

1. Pick a name and check it's free: search hex.pm/packages first —
   `pusher_server` is generic enough to risk a collision.
2. `mix hex.user register` (one-time, creates your hex.pm account)
3. `mix docs` to sanity-check the generated documentation locally
   (writes to `doc/index.html`)
4. `mix hex.publish` from the project root — this uploads the package
   *and* publishes docs to hexdocs.pm in the same step, since `ex_doc` is
   already a configured dev dependency
5. Tag the release in git (`git tag v0.1.0`) so the hex version and your
   version control agree

`mix hex.publish` will show you a dry-run diff of exactly what's being
published before it asks you to confirm — worth reading closely the
first time, since `package[:files]` in `mix.exs` controls what actually
ships (currently `lib`, `mix.exs`, `README.md`, `LICENSE`,
`CHANGELOG.md` — notably not `test/`, which stays local only).

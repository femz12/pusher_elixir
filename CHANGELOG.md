# Changelog

All notable changes to this project are documented here.
Format based on [Keep a Changelog](https://keepachangelog.com/), versioning
follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.0] - 2026-07-09

### Added
- Pusher protocol websocket handshake, subscribe/unsubscribe, ping/pong
- Private and presence channel auth (HMAC-SHA256)
- Presence membership tracking, deduped by `user_id` across connections
- REST trigger endpoint (`POST /apps/:app_id/events`)
- Client events (`client-*`) on private/presence channels
- Webhooks (`channel_occupied`/`vacated`, `member_added`/`removed`, `client_event`)
- Read-only channel info endpoint (`GET /apps/:app_id/channels/:channel`)
- Graceful shutdown (drains connections on SIGTERM) and idle connection timeout
- Test suite for signature verification, presence semantics, and webhook payloads

### Known limitations
- Single-node only — no clustering/distributed presence yet
- No SSL termination built in (put a reverse proxy in front)
- No rate limiting or connection caps
- No batch events endpoint

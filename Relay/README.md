# PocketShell push relay

Private Cloudflare Worker that receives authenticated Herdr and agent hook status events and sends `blocked` / `done` alerts through APNs. It stores device tokens and hashed per-host credentials in Workers KV; the APNs key and pairing credential remain Worker secrets. The two most recent credentials remain valid so re-pairing a host cannot interrupt its existing plugin before the replacement is installed.

## Deploy

1. Create a KV namespace and replace its ID in `wrangler.jsonc`.
2. Enable Push Notifications for `com.bl4ko.pocketshell` and create an APNs `.p8` key.
3. Add secrets with `pnpm dlx wrangler secret put`: `PAIRING_SECRET`, `APNS_TEAM_ID`, `APNS_SANDBOX_KEY_P8`, `APNS_SANDBOX_KEY_ID`, `APNS_PRODUCTION_KEY_P8`, and `APNS_PRODUCTION_KEY_ID`.
4. Run `pnpm test`, then `pnpm run deploy`.
5. Enter the Worker URL and the same pairing secret in PocketShell settings. PocketShell registers the iPhone and installs an authenticated Herdr plugin on each selected SSH host.

This initial relay is one private notification account per Worker deployment. Add user authentication and namespace KV keys by user before offering it as a shared public service.

## Events

Register a host with `PUT /v1/hosts/{uuid}` using the pairing secret and a body of `{"name": "...", "secret": "..."}`. The host then posts events to `POST /v1/hosts/{uuid}/events` with its own secret as the bearer token.

Besides Herdr events, the relay accepts agent hook events:

```json
{"type": "agent.status", "agent_status": "done", "agent": "claude", "tmux_session": "work", "tmux_window_index": 3, "tmux_window_id": "@7", "window_name": "api"}
```

`agent_status` is `done` or `blocked`; the `tmux_*` and `window_name` fields are optional. Strings are capped at 200 characters, unknown fields are ignored, and invalid events return `202 {"ignored": true}`. Alerts carry `hostID`, `hostName`, `backend` (`tmux` or `herdr`) and routing keys. Identical events within five minutes are deduplicated.

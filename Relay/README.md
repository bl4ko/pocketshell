# PocketShell push relay

Private Cloudflare Worker that receives authenticated Herdr status events and sends `blocked` / `done` alerts through APNs. It stores device tokens and hashed per-host credentials in Workers KV; the APNs key and pairing credential remain Worker secrets.

## Deploy

1. Create a KV namespace and replace its ID in `wrangler.jsonc`.
2. Enable Push Notifications for `com.bl4ko.pocketshell` and create an APNs `.p8` key.
3. Add secrets with `npx wrangler secret put`: `PAIRING_SECRET`, `APNS_KEY_P8`, `APNS_KEY_ID`, and `APNS_TEAM_ID`.
4. Run `npm test`, then `npm run deploy`.
5. Enter the Worker URL and the same pairing secret in PocketShell settings. PocketShell registers the iPhone and installs an authenticated Herdr plugin on each selected SSH host.

This initial relay is one private notification account per Worker deployment. Add user authentication and namespace KV keys by user before offering it as a shared public service.

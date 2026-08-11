const encoder = new TextEncoder();
let cachedProviderToken;

export default {
    async fetch(request, env) {
        try {
            return await route(request, env);
        } catch (error) {
            console.error(error);
            return json({ error: "internal_error" }, 500);
        }
    },
};

async function route(request, env) {
    const url = new URL(request.url);
    if (request.method === "GET" && url.pathname === "/health") return json({ ok: true });

    if ((request.method === "POST" || request.method === "DELETE") && url.pathname === "/v1/devices") {
        if (!hasPairingAccess(request, env)) return json({ error: "unauthorized" }, 401);
        const body = await readJSON(request);
        if (!isDevice(body)) return json({ error: "invalid_device" }, 400);
        const key = `device:${body.environment}:${body.token}`;
        if (request.method === "DELETE") await env.PUSH_STATE.delete(key);
        else await env.PUSH_STATE.put(key, JSON.stringify({ addedAt: Date.now() }));
        return json({ ok: true });
    }

    const uuid = "([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})";
    const hostMatch = url.pathname.match(new RegExp(`^/v1/hosts/${uuid}$`, "i"));
    if (request.method === "PUT" && hostMatch) {
        if (!hasPairingAccess(request, env)) return json({ error: "unauthorized" }, 401);
        const body = await readJSON(request);
        if (!body || typeof body.name !== "string" || body.name.length > 100) {
            return json({ error: "invalid_host" }, 400);
        }
        if (typeof body.secret !== "string" || !/^[A-Za-z0-9_-]{32,128}$/.test(body.secret)) {
            return json({ error: "invalid_host_secret" }, 400);
        }
        const key = `host:${hostMatch[1].toLowerCase()}`;
        const previous = await env.PUSH_STATE.get(key, "json");
        const secretHashes = [await sha256(body.secret), ...(previous?.secretHashes || [])];
        await env.PUSH_STATE.put(
            key,
            JSON.stringify({ name: body.name, secretHashes: [...new Set(secretHashes)].slice(0, 2) })
        );
        return json({ ok: true });
    }

    const eventMatch = url.pathname.match(new RegExp(`^/v1/hosts/${uuid}/events$`, "i"));
    if (request.method === "POST" && eventMatch) {
        const hostID = eventMatch[1].toLowerCase();
        const saved = await env.PUSH_STATE.get(`host:${hostID}`, "json");
        const presentedHash = await sha256(bearer(request));
        if (!saved || !saved.secretHashes?.some((hash) => secureEqual(presentedHash, hash))) {
            return json({ error: "unauthorized" }, 401);
        }
        const event = await readJSON(request);
        if (!isPushEvent(event)) return json({ ignored: true }, 202);
        const session = validHeader(request.headers.get("x-herdr-session")) || "default";
        const dedupe = await sha256(`${hostID}\n${session}\n${JSON.stringify(event)}`);
        if (await env.PUSH_STATE.get(`event:${dedupe}`)) return json({ duplicate: true }, 202);
        const payload = { ...pushPayload(hostID, saved.name, session, event), eventID: dedupe.slice(0, 64) };
        const result = await fanOut(env, payload);
        if (result.failed) return json(result, 502);
        await env.PUSH_STATE.put(`event:${dedupe}`, "1", { expirationTtl: 300 });
        return json(result, 202);
    }

    return json({ error: "not_found" }, 404);
}

async function fanOut(env, payload) {
    let cursor;
    let sent = 0;
    let failed = 0;
    do {
        const page = await env.PUSH_STATE.list({ prefix: "device:", cursor });
        cursor = page.list_complete ? undefined : page.cursor;
        const results = await Promise.all(
            page.keys.map(async ({ name }) => {
                const [, environment, token] = name.split(":");
                const response = await sendAPNs(env, environment, token, payload);
                if (response.status === 410 || response.status === 400 && (await apnsReason(response)) === "BadDeviceToken") {
                    await env.PUSH_STATE.delete(name);
                    return true;
                }
                return response.ok;
            })
        );
        sent += results.filter(Boolean).length;
        failed += results.filter((ok) => !ok).length;
    } while (cursor);
    return { sent, failed };
}

async function sendAPNs(env, environment, deviceToken, payload) {
    const host = environment === "sandbox" ? "api.development.push.apple.com" : "api.push.apple.com";
    return fetch(`https://${host}/3/device/${deviceToken}`, {
        method: "POST",
        headers: {
            authorization: `bearer ${await providerToken(env)}`,
            "apns-topic": env.APNS_TOPIC,
            "apns-push-type": "alert",
            "apns-priority": "10",
            "apns-collapse-id": payload.eventID,
            "content-type": "application/json",
        },
        body: JSON.stringify(payload),
    });
}

async function providerToken(env) {
    const now = Math.floor(Date.now() / 1000);
    if (cachedProviderToken && now - cachedProviderToken.createdAt < 50 * 60) return cachedProviderToken.value;
    const header = base64url(encoder.encode(JSON.stringify({ alg: "ES256", kid: env.APNS_KEY_ID })));
    const claims = base64url(encoder.encode(JSON.stringify({ iss: env.APNS_TEAM_ID, iat: now })));
    const unsigned = `${header}.${claims}`;
    const key = await crypto.subtle.importKey(
        "pkcs8",
        pemBytes(env.APNS_KEY_P8),
        { name: "ECDSA", namedCurve: "P-256" },
        false,
        ["sign"]
    );
    const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, encoder.encode(unsigned));
    const value = `${unsigned}.${base64url(new Uint8Array(signature))}`;
    cachedProviderToken = { createdAt: now, value };
    return value;
}

export function pushPayload(hostID, hostName, session, event) {
    const blocked = event.agent_status === "blocked";
    const agent = event.display_agent || event.agent || "Agent";
    const location = session === "default" ? event.workspace_id : `${session} · ${event.workspace_id}`;
    return {
        aps: {
            alert: {
                title: blocked ? "Agent needs input" : "Agent finished",
                body: `${hostName} · ${location} · ${agent}`.slice(0, 180),
            },
            sound: "default",
        },
        hostID,
        backend: "herdr",
        session,
        workspaceID: event.workspace_id,
        paneID: event.pane_id,
    };
}

export function isPushEvent(value) {
    return Boolean(
        value
        && (value.type === "pane_agent_status_changed" || value.type === "pane.agent_status_changed")
        && (value.agent_status === "blocked" || value.agent_status === "done")
        && typeof value.pane_id === "string"
        && typeof value.workspace_id === "string"
    );
}

function isDevice(value) {
    return Boolean(
        value
        && typeof value.token === "string"
        && /^[0-9a-f]{64,200}$/i.test(value.token)
        && (value.environment === "sandbox" || value.environment === "production")
    );
}

async function readJSON(request) {
    if (Number(request.headers.get("content-length") || 0) > 16_384) return null;
    const text = await request.text();
    if (encoder.encode(text).length > 16_384) return null;
    try {
        return JSON.parse(text);
    } catch {
        return null;
    }
}

function bearer(request) {
    const value = request.headers.get("authorization") || "";
    return value.startsWith("Bearer ") ? value.slice(7) : "";
}

function hasPairingAccess(request, env) {
    return typeof env.PAIRING_SECRET === "string"
        && env.PAIRING_SECRET.length >= 16
        && secureEqual(bearer(request), env.PAIRING_SECRET);
}

function validHeader(value) {
    return value && /^[a-zA-Z0-9._ -]{1,100}$/.test(value) ? value : null;
}

function secureEqual(left = "", right = "") {
    const a = encoder.encode(left);
    const b = encoder.encode(right);
    if (a.length !== b.length) return false;
    let difference = 0;
    for (let index = 0; index < a.length; index++) difference |= a[index] ^ b[index];
    return difference === 0;
}

async function sha256(value) {
    const digest = await crypto.subtle.digest("SHA-256", encoder.encode(value));
    return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

function pemBytes(pem) {
    const base64 = pem.replace(/-----[^-]+-----|\s/g, "");
    return Uint8Array.from(atob(base64), (character) => character.charCodeAt(0));
}

function base64url(bytes) {
    let binary = "";
    for (const byte of bytes) binary += String.fromCharCode(byte);
    return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

async function apnsReason(response) {
    try {
        return (await response.clone().json()).reason;
    } catch {
        return undefined;
    }
}

function json(value, status = 200) {
    return Response.json(value, { status, headers: { "cache-control": "no-store" } });
}

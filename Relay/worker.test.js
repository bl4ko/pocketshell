import assert from "node:assert/strict";
import test from "node:test";
import { apnsCredentials, hookPayload, isHookEvent, isPushEvent, pushPayload, route } from "./worker.js";

test("accepts only actionable Herdr status events", () => {
    const event = {
        type: "pane_agent_status_changed",
        pane_id: "w1:p1",
        workspace_id: "w1",
        agent_status: "blocked",
    };
    assert.equal(isPushEvent(event), true);
    assert.equal(isPushEvent({ ...event, agent_status: "working" }), false);
    assert.equal(isPushEvent({ ...event, workspace_id: undefined }), false);
});

test("builds an APNs alert with PocketShell routing data", () => {
    const payload = pushPayload("host-id", "workbox", "agents", {
        pane_id: "w1:p1",
        workspace_id: "w1",
        agent_status: "done",
        display_agent: "Codex",
    });
    assert.equal(payload.aps.alert.title, "Agent finished");
    assert.equal(payload.aps.alert.body, "workbox · agents · w1 · Codex");
    assert.deepEqual(
        {
            hostID: payload.hostID,
            hostName: payload.hostName,
            backend: payload.backend,
            session: payload.session,
            workspaceID: payload.workspaceID,
        },
        { hostID: "host-id", hostName: "workbox", backend: "herdr", session: "agents", workspaceID: "w1" }
    );
});

test("device registration requires the configured pairing secret", async () => {
    const values = new Map();
    const env = {
        PAIRING_SECRET: "correct-pairing-secret",
        PUSH_STATE: {
            put: async (key, value) => values.set(key, value),
            delete: async (key) => values.delete(key),
        },
    };
    const body = JSON.stringify({ token: "a".repeat(64), environment: "sandbox" });
    const request = (authorization) =>
        new Request("https://push.example.test/v1/devices", {
            method: "POST",
            headers: { authorization, "content-type": "application/json" },
            body,
        });

    assert.equal((await route(request("Bearer wrong"), env)).status, 401);
    assert.equal((await route(request("Bearer correct-pairing-secret"), env)).status, 200);
    assert.equal(values.has(`device:sandbox:${"a".repeat(64)}`), true);
    assert.equal((await route(request(""), { ...env, PAIRING_SECRET: undefined })).status, 401);
});

test("selects an APNs key for each environment", () => {
    const env = {
        APNS_SANDBOX_KEY_ID: "sandbox-id",
        APNS_SANDBOX_KEY_P8: "sandbox-key",
        APNS_PRODUCTION_KEY_ID: "production-id",
        APNS_PRODUCTION_KEY_P8: "production-key",
    };
    assert.deepEqual(apnsCredentials(env, "sandbox"), { keyID: "sandbox-id", privateKey: "sandbox-key" });
    assert.deepEqual(apnsCredentials(env, "production"), {
        keyID: "production-id",
        privateKey: "production-key",
    });
});

const hostID = "11111111-2222-3333-4444-555555555555";
const hostSecret = "s".repeat(40);

async function relayEnv() {
    const hash = [...new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(hostSecret)))]
        .map((byte) => byte.toString(16).padStart(2, "0"))
        .join("");
    const values = new Map([
        [`host:${hostID}`, JSON.stringify({ name: "workbox", secretHashes: [hash] })],
        [`device:sandbox:${"a".repeat(64)}`, "{}"],
    ]);
    return {
        APNS_TOPIC: "topic",
        PUSH_STATE: {
            get: async (key, type) => (values.has(key) ? (type === "json" ? JSON.parse(values.get(key)) : values.get(key)) : null),
            put: async (key, value) => values.set(key, value),
            delete: async (key) => values.delete(key),
            list: async () => ({ keys: [...values.keys()].filter((name) => name.startsWith("device:")).map((name) => ({ name })), list_complete: true }),
        },
    };
}

function eventRequest(event, secret = hostSecret) {
    return new Request(`https://push.example.test/v1/hosts/${hostID}/events`, {
        method: "POST",
        headers: { authorization: `Bearer ${secret}`, "content-type": "application/json" },
        body: JSON.stringify(event),
    });
}

const hookEvent = {
    type: "agent.status",
    agent_status: "done",
    agent: "claude",
    tmux_session: "homeops",
    tmux_window_index: 3,
    tmux_window_id: "@7",
    window_name: "api",
    cwd: "/srv/api",
};

test("hook done event builds a tmux payload", () => {
    const payload = hookPayload(hostID, "workbox", hookEvent);
    assert.equal(payload.aps.alert.title, "Agent finished");
    assert.equal(payload.aps.alert.body, "workbox · homeops:3 api · claude");
    assert.deepEqual(
        { hostID: payload.hostID, hostName: payload.hostName, backend: payload.backend, session: payload.session, windowIndex: payload.windowIndex, windowID: payload.windowID },
        { hostID, hostName: "workbox", backend: "tmux", session: "homeops", windowIndex: 3, windowID: "@7" }
    );
});

test("hook blocked event uses the input title", () => {
    const payload = hookPayload(hostID, "workbox", { ...hookEvent, agent_status: "blocked", agent: "codex" });
    assert.equal(payload.aps.alert.title, "Agent needs input");
    assert.equal(payload.aps.alert.body, "workbox · homeops:3 api · codex");
});

test("hook event outside tmux has no location", () => {
    const payload = hookPayload(hostID, "workbox", { type: "agent.status", agent_status: "done", agent: "claude" });
    assert.equal(payload.aps.alert.body, "workbox · claude");
    assert.equal(payload.session, undefined);
    assert.equal(payload.windowIndex, undefined);
    assert.equal(payload.windowID, undefined);
});

test("hook fields are validated and capped", () => {
    assert.equal(isHookEvent({ ...hookEvent, agent_status: "working" }), false);
    assert.equal(isHookEvent({ ...hookEvent, agent: undefined }), false);
    assert.equal(isHookEvent({ ...hookEvent, type: "other" }), false);
    const payload = hookPayload(hostID, "workbox", {
        ...hookEvent,
        agent: "a".repeat(5000),
        tmux_session: "s".repeat(5000),
        window_name: "w".repeat(5000),
        tmux_window_index: -1,
        tmux_window_id: "7",
        extra: "ignored",
    });
    assert.equal(payload.aps.alert.body.length <= 180, true);
    assert.equal(payload.session.length, 200);
    assert.equal(payload.windowIndex, undefined);
    assert.equal(payload.windowID, undefined);
    assert.equal("extra" in payload, false);
});

test("hook events need the host bearer", async () => {
    const env = await relayEnv();
    assert.equal((await route(eventRequest(hookEvent, "wrong"), env)).status, 401);
});

test("invalid hook event is ignored with 202", async () => {
    const env = await relayEnv();
    const response = await route(eventRequest({ ...hookEvent, agent_status: "working" }), env);
    assert.equal(response.status, 202);
    assert.deepEqual(await response.json(), { ignored: true });
});

test("hook event fans out once and then reports a duplicate", async () => {
    const env = await relayEnv();
    const sent = [];
    const originalFetch = globalThis.fetch;
    globalThis.fetch = async (url, init) => {
        sent.push(JSON.parse(init.body));
        return new Response("{}", { status: 200 });
    };
    try {
        env.APNS_SANDBOX_KEY_ID = "kid";
        env.APNS_SANDBOX_KEY_P8 = await testKey();
        const first = await route(eventRequest(hookEvent), env);
        assert.equal(first.status, 202);
        assert.equal(sent.length, 1);
        assert.equal(sent[0].backend, "tmux");
        assert.equal(sent[0].hostName, "workbox");
        assert.equal(typeof sent[0].eventID, "string");
        const second = await route(eventRequest(hookEvent), env);
        assert.equal(second.status, 202);
        assert.deepEqual(await second.json(), { duplicate: true });
        assert.equal(sent.length, 1);
    } finally {
        globalThis.fetch = originalFetch;
    }
});

async function testKey() {
    const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign"]);
    const der = new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey));
    return `-----BEGIN PRIVATE KEY-----\n${btoa(String.fromCharCode(...der))}\n-----END PRIVATE KEY-----`;
}

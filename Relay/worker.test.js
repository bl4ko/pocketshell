import assert from "node:assert/strict";
import test from "node:test";
import { apnsCredentials, isPushEvent, pushPayload, route } from "./worker.js";

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
        { hostID: payload.hostID, backend: payload.backend, session: payload.session, workspaceID: payload.workspaceID },
        { hostID: "host-id", backend: "herdr", session: "agents", workspaceID: "w1" }
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

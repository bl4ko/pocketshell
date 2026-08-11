import assert from "node:assert/strict";
import test from "node:test";
import { isPushEvent, pushPayload } from "./worker.js";

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

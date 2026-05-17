import assert from "node:assert/strict";
import test from "node:test";
import { command, humanMessage } from "../lib/barnowl-client.js";

test("humanMessage prefers bridge message", () => {
  assert.equal(humanMessage({ message: "Loaded." }, "Fallback."), "Loaded.");
  assert.equal(humanMessage({}, "Fallback."), "Fallback.");
});

test("command posts bridge payload with bearer auth", async () => {
  const previousFetch = globalThis.fetch;
  const previousToken = process.env.BARNOWL_BRIDGE_TOKEN;
  process.env.BARNOWL_BRIDGE_TOKEN = "widget-token";

  let captured;
  globalThis.fetch = async (url, init) => {
    captured = { url, init };
    return new Response(JSON.stringify({ ok: true, message: "ok" }), {
      status: 200,
      headers: { "content-type": "application/json" },
    });
  };

  try {
    const response = await command("dashboard_snapshot", { limit: 2 });
    assert.equal(response.ok, true);
    assert.equal(captured.url, "http://127.0.0.1:8765/command");
    assert.equal(captured.init.method, "POST");
    assert.equal(captured.init.headers.authorization, "Bearer widget-token");
    assert.deepEqual(JSON.parse(captured.init.body), {
      command: "dashboard_snapshot",
      limit: 2,
    });
  } finally {
    globalThis.fetch = previousFetch;
    if (previousToken === undefined) {
      delete process.env.BARNOWL_BRIDGE_TOKEN;
    } else {
      process.env.BARNOWL_BRIDGE_TOKEN = previousToken;
    }
  }
});

test("command returns a structured bridge-unavailable response", async () => {
  const previousFetch = globalThis.fetch;
  globalThis.fetch = async () => {
    throw new Error("offline");
  };

  try {
    const response = await command("dashboard_snapshot");
    assert.equal(response.ok, false);
    assert.equal(response.errorCode, "bridge_unavailable");
    assert.match(response.message, /bridge is unavailable/i);
  } finally {
    globalThis.fetch = previousFetch;
  }
});

test("command rewrites native command-version skew into a clear operator message", async () => {
  const previousFetch = globalThis.fetch;
  globalThis.fetch = async () =>
    new Response(
      JSON.stringify({
        ok: false,
        message: "Could not decode Barn Owl command.",
        error:
          "DecodingError.dataCorrupted: Cannot initialize BarnOwlControlCommandName from invalid String value dashboard_snapshot",
      }),
      {
        status: 200,
        headers: { "content-type": "application/json" },
      }
    );

  try {
    const response = await command("dashboard_snapshot");
    assert.equal(response.ok, false);
    assert.equal(response.errorCode, "bridge_command_version_skew");
    assert.match(response.message, /older build/i);
  } finally {
    globalThis.fetch = previousFetch;
  }
});

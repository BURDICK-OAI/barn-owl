import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import test from "node:test";

const port = 8897;
const endpoint = `http://127.0.0.1:${port}/mcp`;

function rpc(method, params = {}, id = 1) {
  return {
    jsonrpc: "2.0",
    id,
    method,
    params,
  };
}

async function postRpc(body) {
  const response = await fetch(endpoint, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
  return response.json();
}

async function waitForServer() {
  const deadline = Date.now() + 4_000;
  while (Date.now() < deadline) {
    try {
      const response = await fetch(`http://127.0.0.1:${port}/`);
      if (response.ok) return;
    } catch {
      await new Promise((resolve) => setTimeout(resolve, 60));
    }
  }
  throw new Error("Barn Owl MCP test server did not start.");
}

test("manual MCP server exposes tools and widget resource", async () => {
  const child = spawn(process.execPath, ["server.js"], {
    cwd: new URL("..", import.meta.url),
    env: {
      ...process.env,
      PORT: String(port),
      BARNOWL_BRIDGE_URL: "http://127.0.0.1:1",
    },
    stdio: "ignore",
  });

  try {
    await waitForServer();

    const initialized = await postRpc(rpc("initialize", {}, 1));
    assert.equal(initialized.result.serverInfo.name, "barnowl");

    const listed = await postRpc(rpc("tools/list", {}, 2));
    const toolNames = listed.result.tools.map((tool) => tool.name);
    assert.ok(toolNames.includes("render_barnowl_dashboard"));
    assert.ok(toolNames.includes("get_dashboard_snapshot"));
    const diagnosticsTool = listed.result.tools.find((tool) => tool.name === "export_diagnostics");
    assert.deepEqual(diagnosticsTool.inputSchema.required, []);

    const resources = await postRpc(rpc("resources/list", {}, 3));
    assert.equal(resources.result.resources[0].uri, "ui://widget/barnowl-dashboard-v1.html");

    const read = await postRpc(
      rpc("resources/read", { uri: "ui://widget/barnowl-dashboard-v1.html" }, 4)
    );
    assert.match(read.result.contents[0].mimeType, /mcp-app/);
    assert.match(read.result.contents[0].text, /Meeting control center/);
    assert.match(read.result.contents[0].text, /selectedMeetingTitle/);
    assert.match(read.result.contents[0].text, /searchQuery/);
    assert.match(read.result.contents[0].text, /ui\/initialize/);
    assert.match(read.result.contents[0].text, /tools\/call/);
    assert.match(read.result.contents[0].text, /requestDisplayMode/);
    assert.match(read.result.contents[0].text, /openai:set_globals/);
    assert.match(
      read.result.contents[0]._meta["openai/widgetDescription"],
      /Interactive Barn Owl meeting control center/
    );

    const dashboard = await postRpc(
      rpc("tools/call", { name: "get_dashboard_snapshot", arguments: {} }, 5)
    );
    assert.equal(dashboard.result.structuredContent.ok, false);
    assert.equal(dashboard.result.structuredContent.dashboard, null);
  } finally {
    child.kill("SIGTERM");
  }
});

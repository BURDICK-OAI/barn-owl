import assert from "node:assert/strict";
import test from "node:test";
import {
  DASHBOARD_URI,
  RESOURCE_MIME_TYPE,
  dashboardRenderMeta,
  dashboardResourceMeta,
  dashboardResourceUiMeta,
  initializeResult,
  visibleInCodexMeta,
} from "../lib/codex-capability-adapter.js";

test("Codex capability adapter owns app-specific metadata", () => {
  assert.equal(DASHBOARD_URI, "ui://widget/barnowl-dashboard-v1.html");
  assert.equal(RESOURCE_MIME_TYPE, "text/html;profile=mcp-app");
  assert.deepEqual(visibleInCodexMeta(), {
    ui: { visibility: ["model", "app"] },
  });
  assert.equal(dashboardRenderMeta()["openai/outputTemplate"], DASHBOARD_URI);
  assert.deepEqual(dashboardResourceUiMeta().csp, {
    connectDomains: [],
    resourceDomains: [],
  });
  assert.match(
    dashboardResourceMeta()["openai/widgetDescription"],
    /Interactive Barn Owl meeting control center/
  );
  assert.deepEqual(dashboardResourceMeta().ui, dashboardResourceUiMeta());
});

test("Codex capability adapter declares the MCP initialize shape", () => {
  const initialized = initializeResult();
  assert.equal(initialized.protocolVersion, "2025-03-26");
  assert.equal(initialized.serverInfo.name, "barnowl");
  assert.deepEqual(initialized.capabilities, {
    tools: {},
    resources: {},
  });
});

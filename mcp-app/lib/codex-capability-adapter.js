export const PROTOCOL_VERSION = "2025-03-26";
export const DASHBOARD_URI = "ui://widget/barnowl-dashboard-v1.html";
export const RESOURCE_MIME_TYPE = "text/html;profile=mcp-app";

const appVisibility = ["model", "app"];

export function visibleInCodexMeta() {
  return {
    ui: { visibility: appVisibility },
  };
}

export function dashboardRenderMeta() {
  return {
    ui: { resourceUri: DASHBOARD_URI, visibility: appVisibility },
    "openai/outputTemplate": DASHBOARD_URI,
    "openai/toolInvocation/invoking": "Opening Barn Owl dashboard",
    "openai/toolInvocation/invoked": "Barn Owl dashboard ready",
  };
}

export function dashboardResourceUiMeta() {
  return {
    prefersBorder: true,
    csp: {
      connectDomains: [],
      resourceDomains: [],
    },
  };
}

export function dashboardResourceMeta() {
  return {
    ui: dashboardResourceUiMeta(),
    "openai/widgetDescription":
      "Interactive Barn Owl meeting control center for recording status, recent sessions, context attachment, and local recovery checks.",
  };
}

export function initializeResult() {
  return {
    protocolVersion: PROTOCOL_VERSION,
    capabilities: {
      tools: {},
      resources: {},
    },
    serverInfo: {
      name: "barnowl",
      version: "0.1.0",
    },
  };
}

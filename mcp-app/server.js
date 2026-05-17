import { createServer } from "node:http";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { command, dashboardSnapshot, humanMessage } from "./lib/barnowl-client.js";
import {
  DASHBOARD_URI,
  RESOURCE_MIME_TYPE,
  dashboardRenderMeta,
  dashboardResourceMeta,
  initializeResult,
  visibleInCodexMeta,
} from "./lib/codex-capability-adapter.js";

const HERE = dirname(fileURLToPath(import.meta.url));
const PORT = Number(process.env.PORT ?? 8787);
const HOST = process.env.HOST ?? "127.0.0.1";
const MCP_PATH = "/mcp";
const DASHBOARD_HTML = readFileSync(join(HERE, "public", "barnowl-widget.html"), "utf8");

const jsonObjectSchema = { type: "object", additionalProperties: true };
const emptyInput = { type: "object", additionalProperties: false, properties: {} };
const uuidString = { type: "string", format: "uuid" };

function objectSchema(properties, required = []) {
  return {
    type: "object",
    additionalProperties: false,
    properties,
    required,
  };
}

function toolDescriptor(name, title, description, inputSchema, outputSchema, extra = {}) {
  return {
    name,
    title,
    description,
    inputSchema,
    outputSchema,
    ...extra,
  };
}

const bridgeOutputSchema = objectSchema(
  {
    ok: { type: "boolean" },
    message: { type: "string" },
    response: jsonObjectSchema,
  },
  ["ok", "message", "response"]
);
const dashboardOutputSchema = objectSchema(
  {
    ok: { type: "boolean" },
    message: { type: "string" },
    dashboard: { anyOf: [jsonObjectSchema, { type: "null" }] },
  },
  ["ok", "message", "dashboard"]
);

const tools = [
  toolDescriptor(
    "render_barnowl_dashboard",
    "Open Barn Owl dashboard",
    "Render the interactive Barn Owl dashboard for recording control, live status, recent meetings, and follow-up actions.",
    emptyInput,
    dashboardOutputSchema,
    {
      annotations: { readOnlyHint: true },
      _meta: dashboardRenderMeta(),
    }
  ),
  toolDescriptor(
    "get_dashboard_snapshot",
    "Get Barn Owl dashboard state",
    "Read current Barn Owl app, recording, readiness, and quick-access meeting state.",
    emptyInput,
    dashboardOutputSchema,
    {
      annotations: { readOnlyHint: true },
      _meta: visibleInCodexMeta(),
    }
  ),
  toolDescriptor(
    "start_recording",
    "Start Barn Owl recording",
    "Start a Barn Owl recording with optional title, meeting type, context, and audio source choices.",
    objectSchema({
      title: { type: "string", minLength: 1 },
      meetingType: { type: "string", minLength: 1 },
      context: { type: "string", minLength: 1 },
      capturesMicrophone: { type: "boolean" },
      capturesSystemAudio: { type: "boolean" },
    }),
    bridgeOutputSchema,
    { _meta: visibleInCodexMeta() }
  ),
  toolDescriptor(
    "stop_recording",
    "Stop Barn Owl recording",
    "Stop the active Barn Owl recording.",
    emptyInput,
    bridgeOutputSchema,
    { _meta: visibleInCodexMeta() }
  ),
  toolDescriptor(
    "set_audio_sources",
    "Set Barn Owl audio sources",
    "Change the microphone and system-audio choices for the next Barn Owl recording.",
    objectSchema({
      capturesMicrophone: { type: "boolean" },
      capturesSystemAudio: { type: "boolean" },
    }),
    dashboardOutputSchema,
    { _meta: visibleInCodexMeta() }
  ),
  toolDescriptor(
    "add_context",
    "Add Barn Owl context",
    "Attach source-labeled context to the active or selected Barn Owl meeting.",
    objectSchema(
      {
        meetingID: uuidString,
        sessionID: uuidString,
        source: { type: "string", minLength: 1 },
        context: { type: "string", minLength: 1 },
      },
      ["context"]
    ),
    bridgeOutputSchema,
    { _meta: visibleInCodexMeta() }
  ),
  toolDescriptor(
    "list_recent_meetings",
    "List recent Barn Owl meetings",
    "List recent Barn Owl meetings, newest first.",
    objectSchema({ limit: { type: "integer", minimum: 1, maximum: 100 } }),
    bridgeOutputSchema,
    { annotations: { readOnlyHint: true } }
  ),
  toolDescriptor(
    "search_meetings",
    "Search Barn Owl meetings",
    "Search Barn Owl meeting memory by topic, person, project, or phrase.",
    objectSchema(
      {
        query: { type: "string", minLength: 1 },
        limit: { type: "integer", minimum: 1, maximum: 100 },
      },
      ["query"]
    ),
    bridgeOutputSchema,
    { annotations: { readOnlyHint: true } }
  ),
  toolDescriptor(
    "get_meeting",
    "Get Barn Owl meeting",
    "Fetch a Barn Owl meeting record by meeting id.",
    objectSchema({ meetingID: uuidString }, ["meetingID"]),
    bridgeOutputSchema,
    { annotations: { readOnlyHint: true } }
  ),
  toolDescriptor(
    "get_meeting_summary",
    "Get Barn Owl meeting summary",
    "Fetch the generated Barn Owl summary for a meeting.",
    objectSchema({ meetingID: uuidString }, ["meetingID"]),
    bridgeOutputSchema,
    { annotations: { readOnlyHint: true } }
  ),
  toolDescriptor(
    "get_meeting_actions",
    "Get Barn Owl meeting actions",
    "Fetch extracted action items for a Barn Owl meeting.",
    objectSchema({ meetingID: uuidString }, ["meetingID"]),
    bridgeOutputSchema,
    { annotations: { readOnlyHint: true } }
  ),
  toolDescriptor(
    "get_meeting_notes",
    "Get Barn Owl meeting notes",
    "Fetch generated Markdown notes for a Barn Owl meeting.",
    objectSchema({ meetingID: uuidString }, ["meetingID"]),
    bridgeOutputSchema,
    { annotations: { readOnlyHint: true } }
  ),
  toolDescriptor(
    "ask_notes",
    "Ask Barn Owl notes",
    "Ask a question about a specific Barn Owl meeting or the currently open meeting.",
    objectSchema(
      {
        meetingID: uuidString,
        prompt: { type: "string", minLength: 1 },
      },
      ["prompt"]
    ),
    bridgeOutputSchema
  ),
  toolDescriptor(
    "update_notes",
    "Update Barn Owl notes",
    "Revise Barn Owl notes for a meeting using a user-provided prompt.",
    objectSchema(
      {
        sessionID: uuidString,
        prompt: { type: "string", minLength: 1 },
      },
      ["prompt"]
    ),
    bridgeOutputSchema,
    { _meta: visibleInCodexMeta() }
  ),
  toolDescriptor(
    "get_context_review",
    "Get Barn Owl context review",
    "Read a pending post-recording Barn Owl context review for a meeting.",
    objectSchema({ meetingID: uuidString }, ["meetingID"]),
    bridgeOutputSchema,
    { annotations: { readOnlyHint: true } }
  ),
  toolDescriptor(
    "apply_context_review",
    "Apply Barn Owl context review",
    "Apply the pending context review, optionally with edited freeform context.",
    objectSchema(
      {
        meetingID: uuidString,
        context: { type: "string", minLength: 1 },
      },
      ["meetingID"]
    ),
    bridgeOutputSchema
  ),
  toolDescriptor(
    "dismiss_context_review",
    "Dismiss Barn Owl context review",
    "Dismiss the current pending context review for now.",
    objectSchema({ meetingID: uuidString }, ["meetingID"]),
    bridgeOutputSchema
  ),
  toolDescriptor(
    "list_jobs",
    "List Barn Owl jobs",
    "List Barn Owl background jobs, optionally scoped to a meeting.",
    objectSchema({ meetingID: uuidString }),
    bridgeOutputSchema,
    { annotations: { readOnlyHint: true } }
  ),
  toolDescriptor(
    "retry_job",
    "Retry Barn Owl job",
    "Retry a Barn Owl background job by id.",
    objectSchema({
      meetingID: uuidString,
      jobID: uuidString,
    }),
    bridgeOutputSchema
  ),
  toolDescriptor(
    "export_diagnostics",
    "Export Barn Owl diagnostics",
    "Export Barn Owl developer diagnostics to a local path.",
    objectSchema({ outputPath: { type: "string", minLength: 1 } }),
    bridgeOutputSchema
  ),
  toolDescriptor(
    "check_permissions",
    "Check Barn Owl permissions",
    "Check Barn Owl setup permissions and readiness state.",
    emptyInput,
    bridgeOutputSchema,
    { annotations: { readOnlyHint: true } }
  ),
  toolDescriptor(
    "open_settings",
    "Open Barn Owl Settings",
    "Open the native Barn Owl Settings window on this Mac.",
    emptyInput,
    bridgeOutputSchema,
    { _meta: visibleInCodexMeta() }
  ),
  toolDescriptor(
    "open_notes_folder",
    "Open Barn Owl notes folder",
    "Open the Barn Owl Markdown notes folder in Finder.",
    emptyInput,
    bridgeOutputSchema,
    { _meta: visibleInCodexMeta() }
  ),
];

const toolHandlers = {
  async render_barnowl_dashboard() {
    return structuredDashboardResult(await dashboardSnapshot());
  },
  async get_dashboard_snapshot() {
    return structuredDashboardResult(await dashboardSnapshot());
  },
  async start_recording(args) {
    return structuredBridgeResult(await command("start_recording", args), "Recording request sent.");
  },
  async stop_recording() {
    return structuredBridgeResult(await command("stop_recording"), "Stop request sent.");
  },
  async set_audio_sources(args) {
    return structuredDashboardResult(await command("set_audio_sources", args));
  },
  async add_context(args) {
    return structuredBridgeResult(await command("add_context", args), "Context attachment request sent.");
  },
  async list_recent_meetings(args) {
    return structuredBridgeResult(await command("meetings_recent", args), "Recent meetings loaded.");
  },
  async search_meetings(args) {
    return structuredBridgeResult(await command("meetings_search", args), "Meeting search complete.");
  },
  async get_meeting(args) {
    return structuredBridgeResult(await command("meeting_get", args), "Meeting loaded.");
  },
  async get_meeting_summary(args) {
    return structuredBridgeResult(await command("meeting_summary", args), "Meeting summary loaded.");
  },
  async get_meeting_actions(args) {
    return structuredBridgeResult(await command("meeting_actions", args), "Meeting actions loaded.");
  },
  async get_meeting_notes(args) {
    return structuredBridgeResult(await command("meeting_notes", args), "Meeting notes loaded.");
  },
  async ask_notes(args) {
    return structuredBridgeResult(await command("ask_notes", args), "Barn Owl note question answered.");
  },
  async update_notes(args) {
    return structuredBridgeResult(await command("update_notes", args), "Barn Owl note update requested.");
  },
  async get_context_review(args) {
    return structuredBridgeResult(await command("meeting_context_review", args), "Context review loaded.");
  },
  async apply_context_review(args) {
    return structuredBridgeResult(await command("meeting_context_review_apply", args), "Context review applied.");
  },
  async dismiss_context_review(args) {
    return structuredBridgeResult(await command("meeting_context_review_dismiss", args), "Context review dismissed.");
  },
  async list_jobs(args) {
    return structuredBridgeResult(await command("jobs_list", args), "Jobs loaded.");
  },
  async retry_job(args) {
    return structuredBridgeResult(await command("jobs_retry", args), "Job retry requested.");
  },
  async export_diagnostics(args) {
    return structuredBridgeResult(await command("diagnostics_export", args), "Diagnostics export requested.");
  },
  async check_permissions() {
    return structuredBridgeResult(await command("permissions_check"), "Permissions status loaded.");
  },
  async open_settings() {
    return structuredBridgeResult(await command("open_settings"), "Barn Owl Settings opened.");
  },
  async open_notes_folder() {
    return structuredBridgeResult(await command("open_notes_folder"), "Barn Owl notes folder opened.");
  },
};

function structuredBridgeResult(response, fallbackMessage) {
  return {
    content: [{ type: "text", text: humanMessage(response, fallbackMessage) }],
    structuredContent: {
      ok: response?.ok === true,
      message: humanMessage(response, fallbackMessage),
      response,
    },
  };
}

function structuredDashboardResult(response) {
  return {
    content: [{ type: "text", text: humanMessage(response, "Barn Owl dashboard snapshot.") }],
    structuredContent: {
      ok: response?.ok === true,
      message: humanMessage(response, "Barn Owl dashboard snapshot."),
      dashboard: response?.dashboard ?? null,
    },
    _meta: {
      fullBridgeResponse: response,
    },
  };
}

function resourcesList() {
  return {
    resources: [
      {
        uri: DASHBOARD_URI,
        name: "Barn Owl dashboard widget",
        description: "Interactive Barn Owl dashboard widget.",
        mimeType: RESOURCE_MIME_TYPE,
      },
    ],
  };
}

function resourcesRead(uri) {
  if (uri !== DASHBOARD_URI) {
    throw rpcError(-32002, `Unknown resource: ${uri}`);
  }
  return {
    contents: [
      {
        uri: DASHBOARD_URI,
        mimeType: RESOURCE_MIME_TYPE,
        text: DASHBOARD_HTML,
        _meta: dashboardResourceMeta(),
      },
    ],
  };
}

function rpcError(code, message) {
  const error = new Error(message);
  error.code = code;
  return error;
}

function rpcSuccess(id, result) {
  return { jsonrpc: "2.0", id, result };
}

function rpcFailure(id, error) {
  return {
    jsonrpc: "2.0",
    id,
    error: {
      code: Number.isInteger(error?.code) ? error.code : -32603,
      message: error instanceof Error ? error.message : String(error),
    },
  };
}

async function handleRpc(message) {
  const id = message?.id ?? null;
  const method = message?.method;
  const params = message?.params ?? {};

  switch (method) {
    case "initialize":
      return rpcSuccess(id, initializeResult());
    case "notifications/initialized":
      return null;
    case "ping":
      return rpcSuccess(id, {});
    case "tools/list":
      return rpcSuccess(id, { tools });
    case "resources/list":
      return rpcSuccess(id, resourcesList());
    case "resources/read":
      return rpcSuccess(id, resourcesRead(params.uri));
    case "tools/call": {
      const handler = toolHandlers[params.name];
      if (!handler) {
        throw rpcError(-32601, `Unknown tool: ${params.name}`);
      }
      return rpcSuccess(id, await handler(params.arguments ?? {}));
    }
    default:
      throw rpcError(-32601, `Unknown method: ${method}`);
  }
}

async function parseBody(req) {
  let body = "";
  for await (const chunk of req) {
    body += chunk;
    if (body.length > 1_000_000) {
      throw rpcError(-32000, "Request body too large.");
    }
  }
  if (!body.trim()) {
    return null;
  }
  return JSON.parse(body);
}

function writeJson(res, status, body) {
  res.writeHead(status, {
    "content-type": "application/json",
    "access-control-allow-origin": "*",
    "access-control-expose-headers": "Mcp-Session-Id",
  });
  res.end(JSON.stringify(body));
}

const httpServer = createServer(async (req, res) => {
  if (!req.url) {
    res.writeHead(400).end("Missing URL");
    return;
  }
  const url = new URL(req.url, `http://${req.headers.host ?? "localhost"}`);

  if (req.method === "GET" && url.pathname === "/") {
    res.writeHead(200, { "content-type": "text/plain" }).end("Barn Owl MCP server");
    return;
  }

  if (req.method === "OPTIONS" && url.pathname === MCP_PATH) {
    res.writeHead(204, {
      "access-control-allow-origin": "*",
      "access-control-allow-methods": "POST, OPTIONS",
      "access-control-allow-headers": "content-type, mcp-session-id",
      "access-control-expose-headers": "Mcp-Session-Id",
    });
    res.end();
    return;
  }

  if (url.pathname !== MCP_PATH || req.method !== "POST") {
    res.writeHead(404).end("Not Found");
    return;
  }

  try {
    const payload = await parseBody(req);
    if (Array.isArray(payload)) {
      const results = (await Promise.all(payload.map((message) => handleRpc(message)))).filter(Boolean);
      writeJson(res, 200, results);
      return;
    }
    const result = await handleRpc(payload);
    if (result === null) {
      res.writeHead(202).end();
      return;
    }
    writeJson(res, 200, result);
  } catch (error) {
    writeJson(res, 200, rpcFailure(null, error));
  }
});

httpServer.listen(PORT, HOST, () => {
  console.log(`Barn Owl MCP server listening on http://${HOST}:${PORT}${MCP_PATH}`);
});

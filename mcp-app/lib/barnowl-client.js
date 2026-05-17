import { readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";

const DEFAULT_BRIDGE_URL = process.env.BARNOWL_BRIDGE_URL ?? "http://127.0.0.1:8765";
const DEFAULT_TOKEN_PATH =
  process.env.BARNOWL_BRIDGE_TOKEN_PATH ??
  join(homedir(), "Library", "Application Support", "Barn Owl", "control-bridge-token");

async function bridgeToken() {
  if (process.env.BARNOWL_BRIDGE_TOKEN?.trim()) {
    return process.env.BARNOWL_BRIDGE_TOKEN.trim();
  }
  try {
    return (await readFile(DEFAULT_TOKEN_PATH, "utf8")).trim();
  } catch {
    return "";
  }
}

async function requestBridge(path, init = {}) {
  const token = await bridgeToken();
  const headers = {
    "content-type": "application/json",
    ...(init.headers ?? {}),
  };
  if (token) {
    headers.authorization = `Bearer ${token}`;
  }

  let response;
  try {
    response = await fetch(`${DEFAULT_BRIDGE_URL}${path}`, {
      ...init,
      headers,
    });
  } catch (error) {
    return {
      ok: false,
      message: "Barn Owl control bridge is unavailable. Is Barn Owl running?",
      error: error instanceof Error ? error.message : String(error),
      errorCode: "bridge_unavailable",
    };
  }

  const text = await response.text();
  try {
    const parsed = JSON.parse(text);
    if (
      parsed?.ok === false &&
      typeof parsed?.error === "string" &&
      parsed.error.includes("Cannot initialize BarnOwlControlCommandName from invalid String value")
    ) {
      return {
        ...parsed,
        message:
          "Barn Owl is running an older build than this MCP app expects. Update or relaunch Barn Owl, then retry.",
        errorCode: "bridge_command_version_skew",
      };
    }
    return parsed;
  } catch {
    return {
      ok: false,
      message: text || `Barn Owl bridge returned HTTP ${response.status}.`,
      error: text || `HTTP ${response.status}`,
      errorCode: "invalid_bridge_response",
    };
  }
}

export function command(command, payload = {}) {
  return requestBridge("/command", {
    method: "POST",
    body: JSON.stringify({ command, ...payload }),
  });
}

export function dashboardSnapshot() {
  return command("dashboard_snapshot");
}

export function humanMessage(response, fallback) {
  return response?.message || fallback;
}

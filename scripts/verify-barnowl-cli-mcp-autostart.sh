#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "$ROOT_DIR/scripts/barnowl" <<'PY'
import runpy
import sys
from pathlib import Path

namespace = runpy.run_path(sys.argv[1], run_name="barnowl_cli_mcp_autostart_check")
calls = {"health": 0, "popen": 0}

def fake_healthcheck(url=namespace["DEFAULT_MCP_HEALTH_URL"]):
    calls["health"] += 1
    return False

def fake_server():
    return Path("/tmp/CodexMCPApp/server.js")

def fake_node():
    return "/usr/bin/node"

class FakeProcess:
    pass

def fake_popen(command, **kwargs):
    calls["popen"] += 1
    assert command == ["/usr/bin/node", "/tmp/CodexMCPApp/server.js"], command
    assert kwargs["start_new_session"] is True, kwargs
    assert kwargs["stdin"] is namespace["subprocess"].DEVNULL, kwargs
    assert kwargs["stdout"] is namespace["subprocess"].DEVNULL, kwargs
    assert kwargs["stderr"] is namespace["subprocess"].DEVNULL, kwargs
    return FakeProcess()

globals_dict = namespace["maybe_start_mcp_server"].__globals__
globals_dict["mcp_healthcheck"] = fake_healthcheck
globals_dict["resolve_mcp_server"] = fake_server
globals_dict["resolve_node_binary"] = fake_node
globals_dict["subprocess"].Popen = fake_popen

assert namespace["maybe_start_mcp_server"]() is True
assert calls == {"health": 1, "popen": 1}, calls

namespace["os"].environ["BARNOWL_MCP_AUTOSTART"] = "0"
assert namespace["maybe_start_mcp_server"]() is False
assert calls == {"health": 1, "popen": 1}, calls
PY

echo "barnowl_cli_mcp_autostart_check=true"

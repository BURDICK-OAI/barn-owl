#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "$ROOT_DIR/scripts/barnowl" <<'PY'
import runpy
import sys

namespace = runpy.run_path(sys.argv[1], run_name="barnowl_cli_timeout_check")
calls = {"post": 0, "status": 0, "open": 0}

def fake_post_once(payload, base_url):
    calls["post"] += 1
    return {
        "ok": False,
        "message": "Barn Owl control bridge is unavailable. Is Barn Owl running?",
        "error": "timed out",
    }

def fake_status(base_url):
    calls["status"] += 1
    return {
        "ok": True,
        "status": "Preparing",
        "recordingStatus": "preparing",
        "captureStatus": "Requesting microphone permission.",
    }

def fake_open():
    calls["open"] += 1

globals_dict = namespace["post"].__globals__
globals_dict["post_once"] = fake_post_once
globals_dict["get_status_once"] = fake_status
globals_dict["open_barn_owl"] = fake_open

response = namespace["post"](
    {"command": "start_recording"},
    "http://127.0.0.1:8765",
    launch=True,
)

assert response["ok"] is True, response
assert response["captureStatus"] == "Requesting microphone permission.", response
assert response["nextCommand"] == "barnowl status --format json", response
assert "permission prompt" in response["message"], response
assert calls == {"post": 1, "status": 1, "open": 0}, calls
PY

echo "barnowl_cli_start_timeout_check=true"

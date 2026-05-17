#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "$ROOT_DIR/scripts/barnowl" <<'PY'
import runpy
import sys

namespace = runpy.run_path(sys.argv[1], run_name="barnowl_cli_stop_review_check")
meeting_id = "00000000-0000-0000-0000-00000000C077"
calls = {"post": [], "wait": [], "print": []}

def fake_post(payload, base_url, launch=True):
    calls["post"].append((payload, base_url, launch))
    return {
        "ok": True,
        "meetingID": meeting_id,
        "activeMeetingID": meeting_id,
        "message": "Recording stopped.",
    }

def fake_wait(payload, base_url, timeout_seconds, launch=True):
    calls["wait"].append((payload, base_url, timeout_seconds, launch))
    return {
        "ok": True,
        "meetingID": meeting_id,
        "activeMeetingID": meeting_id,
        "contextReviewReady": True,
        "contextReview": {
            "meetingID": meeting_id,
            "suggestedSummary": "Transcript suggestions ready.",
        },
        "message": "Wait condition satisfied: review.",
    }

def fake_print(response, output_format, human):
    calls["print"].append((response, output_format, human))
    return 0 if response.get("ok") else 1

globals_dict = namespace["main"].__globals__
globals_dict["post"] = fake_post
globals_dict["wait_for_condition"] = fake_wait
globals_dict["print_response"] = fake_print

exit_code = namespace["main"]([
    "--no-launch",
    "--format",
    "json",
    "stop",
    "--wait-review",
    "--timeout",
    "90s",
])

assert exit_code == 0, exit_code
assert calls["post"] == [
    ({"command": "stop_recording"}, "http://127.0.0.1:8765", False)
], calls
wait_payload, wait_url, wait_timeout, wait_launch = calls["wait"][0]
assert wait_payload == {
    "command": "wait",
    "sessionID": meeting_id,
    "latest": False,
    "until": "review",
    "format": "json",
}, wait_payload
assert wait_url == "http://127.0.0.1:8765", wait_url
assert wait_timeout == 90.0, wait_timeout
assert wait_launch is False, wait_launch
assert len(calls["print"]) == 1, calls
printed_response, output_format, human = calls["print"][0]
assert printed_response["contextReviewReady"] is True, printed_response
assert printed_response["contextReview"]["meetingID"] == meeting_id, printed_response
assert output_format == "json", output_format
assert human is False, human
PY

echo "barnowl_cli_stop_review_check=true"

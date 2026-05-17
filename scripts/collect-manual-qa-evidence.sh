#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_PATH="${1:-"$ROOT_DIR/.build/manual-qa/manual-capture-qa-evidence-$(date +%Y%m%d-%H%M%S).md"}"
APP_ARTIFACT="${BARNOWL_QA_APP_ARTIFACT:-"$ROOT_DIR/dist/BarnOwl.app.zip"}"
INSTALLED_APP="${BARNOWL_QA_INSTALLED_APP:-"/Applications/Barn Owl.app"}"
CHUNK_ROOT="${BARNOWL_QA_CHUNK_ROOT:-"${TMPDIR:-/tmp}/BarnOwl/AudioChunks"}"
APP_SUPPORT_ROOT="${BARNOWL_QA_APP_SUPPORT_ROOT:-"$HOME/Library/Application Support/Barn Owl"}"
LOG_FILE="$APP_SUPPORT_ROOT/Logs/barnowl.log.jsonl"
TEMP_DIRS=()

mkdir -p "$(dirname "$OUTPUT_PATH")"

cleanup_temp_dirs() {
  for dir in "${TEMP_DIRS[@]}"; do
    [[ -n "$dir" ]] && rm -rf "$dir"
  done
}
trap cleanup_temp_dirs EXIT

redact_path() {
  local value="$1"
  value="${value//$HOME/~}"
  printf '%s\n' "$value"
}

redact_text() {
  sed -E \
    -e "s|$HOME|~|g" \
    -e 's/sk-(proj-)?[A-Za-z0-9_-]{8,}/[REDACTED_OPENAI_API_KEY]/g' \
    -e 's/(Authorization:[[:space:]]*Bearer[[:space:]]+)[A-Za-z0-9._~+\/=-]{8,}/\1[REDACTED_BEARER_TOKEN]/Ig' \
    -e 's/(OPENAI_API_KEY|BARNOWL_API_KEY_TO_INSTALL)[[:space:]]*=[[:space:]]*[^[:space:]]+/\1=[REDACTED]/Ig'
}

append_section() {
  printf '\n## %s\n\n' "$1"
}

plist_value() {
  local plist="$1"
  local key="$2"
  /usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null || printf 'missing'
}

inspect_app_artifact() {
  local artifact="$1"
  local work_dir=""
  local app_path="$artifact"

  if [[ ! -e "$artifact" ]]; then
    printf 'App artifact: missing at `%s`\n' "$(redact_path "$artifact")"
    return
  fi

  if [[ -f "$artifact" ]]; then
    printf -- '- Artifact SHA-256: `%s`\n' "$(shasum -a 256 "$artifact" | awk '{print $1}')"
  else
    printf -- '- Artifact SHA-256: `not_applicable_for_directory_artifact`\n'
  fi

  if [[ "$artifact" == *.zip ]]; then
    work_dir="$(mktemp -d "${TMPDIR:-/tmp}/barnowl-qa-app.XXXXXX")"
    TEMP_DIRS+=("$work_dir")
    /usr/bin/ditto -x -k "$artifact" "$work_dir"
    app_path="$(find "$work_dir" -maxdepth 3 -name '*.app' -type d | head -n 1)"
  fi

  if [[ -z "$app_path" || ! -d "$app_path" ]]; then
    printf 'App artifact: no `.app` bundle found in `%s`\n' "$(redact_path "$artifact")"
    [[ -n "$work_dir" ]] && rm -rf "$work_dir"
    return
  fi

  local plist="$app_path/Contents/Info.plist"
  printf -- '- Artifact: `%s`\n' "$(redact_path "$artifact")"
  printf -- '- Bundle ID: `%s`\n' "$(plist_value "$plist" CFBundleIdentifier)"
  printf -- '- Version: `%s (%s)`\n' "$(plist_value "$plist" CFBundleShortVersionString)" "$(plist_value "$plist" CFBundleVersion)"
  printf -- '- Microphone usage string: `%s`\n' "$(plist_value "$plist" NSMicrophoneUsageDescription)"
  printf -- '- System-audio usage string: `%s`\n' "$(plist_value "$plist" NSAudioCaptureUsageDescription)"
  printf -- '- Screen-capture usage string: `%s`\n' "$(plist_value "$plist" NSScreenCaptureUsageDescription)"

  if /usr/bin/codesign --verify --deep --strict "$app_path" >/dev/null 2>&1; then
    printf -- '- Codesign: `valid`\n'
  else
    printf -- '- Codesign: `invalid`\n'
  fi

  local signature_info
  signature_info="$(/usr/bin/codesign -dv --verbose=4 "$app_path" 2>&1)"
  if echo "$signature_info" | grep -q 'flags=.*runtime'; then
    printf -- '- Hardened runtime: `true`\n'
  else
    printf -- '- Hardened runtime: `false`\n'
  fi

  [[ -n "$work_dir" ]] && rm -rf "$work_dir"
}

inspect_installed_app() {
  local app_path="$1"
  if [[ ! -d "$app_path" ]]; then
    printf -- '- Installed app: `missing at %s`\n' "$(redact_path "$app_path")"
    return
  fi

  local plist="$app_path/Contents/Info.plist"
  local cli_path="$app_path/Contents/MacOS/barnowl"
  local skill_path="$app_path/Contents/Resources/CodexSkill/barnowl/SKILL.md"
  local skill_wrapper="$app_path/Contents/Resources/CodexSkill/barnowl/scripts/barnowl"
  local mcp_server="$app_path/Contents/Resources/CodexMCPApp/server.js"
  local mcp_client="$app_path/Contents/Resources/CodexMCPApp/lib/barnowl-client.js"
  local mcp_capability_adapter="$app_path/Contents/Resources/CodexMCPApp/lib/codex-capability-adapter.js"
  local mcp_widget="$app_path/Contents/Resources/CodexMCPApp/public/barnowl-widget.html"
  printf -- '- Installed app: `%s`\n' "$(redact_path "$app_path")"
  printf -- '- Installed bundle ID: `%s`\n' "$(plist_value "$plist" CFBundleIdentifier)"
  printf -- '- Installed version: `%s (%s)`\n' "$(plist_value "$plist" CFBundleShortVersionString)" "$(plist_value "$plist" CFBundleVersion)"

  if /usr/bin/codesign --verify --deep --strict "$app_path" >/dev/null 2>&1; then
    printf -- '- Installed codesign: `valid`\n'
  else
    printf -- '- Installed codesign: `invalid`\n'
  fi

  local signature_info
  signature_info="$(/usr/bin/codesign -dv --verbose=4 "$app_path" 2>&1)"
  if echo "$signature_info" | grep -q 'flags=.*runtime'; then
    printf -- '- Installed hardened runtime: `true`\n'
  else
    printf -- '- Installed hardened runtime: `false`\n'
  fi

  if [[ -x "$cli_path" ]]; then
    printf -- '- Installed CLI executable: `true`\n'
  else
    printf -- '- Installed CLI executable: `false`\n'
  fi

  if [[ -f "$skill_path" && -x "$skill_wrapper" ]]; then
    printf -- '- Installed Codex skill: `present`\n'
  else
    printf -- '- Installed Codex skill: `missing`\n'
  fi

  if [[ -f "$mcp_server" && -f "$mcp_client" && -f "$mcp_capability_adapter" && -f "$mcp_widget" ]]; then
    printf -- '- Installed Codex MCP app: `present`\n'
  else
    printf -- '- Installed Codex MCP app: `missing`\n'
  fi

}

file_count() {
  local dir="$1"
  shift
  if [[ ! -d "$dir" ]]; then
    printf '0'
    return
  fi
  find "$dir" "$@" -type f 2>/dev/null | wc -l | tr -d ' '
}

summarize_diagnostics_log() {
  local log_file="$1"
  if [[ ! -f "$log_file" ]]; then
    printf 'diagnostics log does not exist\n'
    return
  fi

  printf 'total_entries=%s\n' "$(wc -l <"$log_file" | tr -d ' ')"
  printf '\nRecent category/level/timestamp metadata only:\n'
  tail -n 80 "$log_file" | sed -nE \
    's/.*"category":"([^"]*)".*"level":"([^"]*)".*"timestamp":"([^"]*)".*/timestamp=\3 level=\2 category=\1/p' \
    | tail -n 40 \
    | redact_text

  printf '\nRecent category counts:\n'
  tail -n 200 "$log_file" | sed -nE 's/.*"category":"([^"]*)".*/\1/p' \
    | sort \
    | uniq -c \
    | sort -nr \
    | head -n 20 \
    | redact_text

  printf '\nRecent level counts:\n'
  tail -n 200 "$log_file" | sed -nE 's/.*"level":"([^"]*)".*/\1/p' \
    | sort \
    | uniq -c \
    | sort -nr \
    | redact_text
}

{
  printf '# Barn Owl Manual Capture QA Evidence\n\n'
  printf 'Generated: `%s`\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'Host: `%s`\n' "$(hostname | redact_text)"
  printf 'Workspace: `%s`\n' "$(redact_path "$ROOT_DIR")"

  append_section "System"
  printf '```text\n'
  sw_vers 2>/dev/null | redact_text || true
  cpu_brand="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || printf 'unknown')"
  printf 'Hardware: %s\n' "$cpu_brand" | redact_text
  printf 'Architecture: %s\n' "$(uname -m)"
  printf '```\n'

  append_section "Git"
  printf '```text\n'
  git -C "$ROOT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null | sed 's/^/branch=/' | redact_text || true
  git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null | sed 's/^/commit=/' | redact_text || true
  git -C "$ROOT_DIR" status --short 2>/dev/null | head -n 40 | redact_text || true
  printf '```\n'

  append_section "App Artifact"
  inspect_app_artifact "$APP_ARTIFACT"

  append_section "Installed App"
  inspect_installed_app "$INSTALLED_APP"

  append_section "Permission Reset Commands Used"
  cat <<'EOF'
Record whether these were run before this QA pass:

- [ ] `tccutil reset Microphone com.barnowl.mac`
- [ ] `tccutil reset ScreenCapture com.barnowl.mac`
- [ ] `tccutil reset AudioCapture com.barnowl.mac` if supported by this macOS version
EOF

  append_section "Manual Flow Results"
  cat <<'EOF'
Fill these in during the pass:

- [ ] First-run grant path passed
- [ ] Microphone denied path passed
- [ ] System-audio denied path passed
- [ ] Previously denied retry path passed
- [ ] Permission revoked while recording path passed
- [ ] Source unavailable case passed or documented as not applicable
- [ ] Realtime preview produced visible text while recording
- [ ] Final notes and transcript are visible
- [ ] Live preview stayed visually separate from final transcript
- [ ] Transcript utility panels preserve app scrolling and remain responsive
- [ ] Add Details, Review Auto Context, and Context Library labels are clear
- [ ] Settings Context Library stays compact and opens management for view create edit and delete
- [ ] No secrets, private paths, transcript excerpts, or raw audio payloads appeared in user-facing errors
EOF

  append_section "CLI Codex Feedback Results"
  cat <<'EOF'
Fill these in during the pass:

- [ ] Installed CLI status command passed
- [ ] CLI start stop wait notes flow passed or was covered by the manual recording flow
- [ ] CLI diagnostics export produced a redacted report
- [ ] CLI feedback Slack draft produced a redacted draft without posting
- [ ] CLI feedback Slack post requires explicit confirmation and configured webhook
- [ ] Bundled Codex skill guidance matches the installed CLI behavior
- [ ] Bundled Codex MCP app resources are present
- [ ] Installed Codex MCP app smoke passed
EOF

  append_section "Temp Audio Evidence"
  printf -- '- Chunk root: `%s`\n' "$(redact_path "$CHUNK_ROOT")"
  printf -- '- Metadata files: `%s`\n' "$(file_count "$CHUNK_ROOT" -name '*.json')"
  printf -- '- Raw audio files: `%s`\n' "$(file_count "$CHUNK_ROOT" \( -name '*.caf' -o -name '*.wav' -o -name '*.m4a' \))"
  printf '\nRecent files, redacted and truncated:\n\n'
  printf '```text\n'
  if [[ -d "$CHUNK_ROOT" ]]; then
    find "$CHUNK_ROOT" -maxdepth 4 -type f -print 2>/dev/null | sort | tail -n 80 | redact_text
  else
    printf 'chunk root does not exist\n'
  fi
  printf '```\n'

  append_section "Diagnostics Log Summary"
  printf -- '- Log file: `%s`\n' "$(redact_path "$LOG_FILE")"
  printf '\nRecent diagnostics metadata, omitting message/details to avoid preserving meeting text:\n\n'
  printf '```text\n'
  summarize_diagnostics_log "$LOG_FILE"
  printf '```\n'

  append_section "Screenshots And Recordings To Attach"
  cat <<'EOF'
- Permission prompts or System Settings permission panes
- Preparing, recording, processing, completed, and failure/retry states
- Realtime preview showing live text during recording
- Temp audio directory while recording
- Temp audio directory after finalization
- Completed meeting notes/transcript/history view
EOF
} >"$OUTPUT_PATH"

printf '%s\n' "$OUTPUT_PATH"

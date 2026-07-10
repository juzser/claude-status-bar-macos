#!/bin/bash
# Integration test for the claude-status-hook binary.
# Builds nothing itself — expects `swift build` output in .build/debug.
set -u

BIN="${1:-.build/debug/claude-status-hook}"
if [[ ! -x "$BIN" ]]; then
  echo "FAIL: binary not found at $BIN (run: swift build)"; exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export CLAUDE_STATUS_BAR_HOME="$TMP"
FAILURES=0

check() { # <desc> <exit_code>
  if [[ "$2" -ne 0 ]]; then echo "FAIL: $1"; FAILURES=$((FAILURES+1)); else echo "ok: $1"; fi
}

# 1. SessionStart creates an idle session file
echo '{"session_id":"it-1","cwd":"/tmp/proj"}' | "$BIN" SessionStart
check "SessionStart exits 0" $?
python3 - "$TMP/sessions/it-1.json" <<'EOF'
import json, sys
rec = json.load(open(sys.argv[1]))
assert rec["sessionId"] == "it-1", rec
assert rec["state"] == "idle", rec
assert rec["cwd"] == "/tmp/proj", rec
EOF
check "SessionStart writes idle record" $?

# 2. UserPromptSubmit -> thinking with busySince
echo '{"session_id":"it-1","cwd":"/tmp/proj"}' | "$BIN" UserPromptSubmit
python3 - "$TMP/sessions/it-1.json" <<'EOF'
import json, sys
rec = json.load(open(sys.argv[1]))
assert rec["state"] == "thinking", rec
assert rec.get("busySince"), rec
EOF
check "UserPromptSubmit -> thinking + busySince" $?

# 3. PreToolUse -> tool with mapped label
echo '{"session_id":"it-1","cwd":"/tmp/proj","tool_name":"Bash"}' | "$BIN" PreToolUse
python3 - "$TMP/sessions/it-1.json" <<'EOF'
import json, sys
rec = json.load(open(sys.argv[1]))
assert rec["state"] == "tool", rec
assert rec["label"] == "Running", rec
EOF
check "PreToolUse -> tool/Running" $?

# 4. Stop -> idle, busySince cleared
echo '{"session_id":"it-1","cwd":"/tmp/proj"}' | "$BIN" Stop
python3 - "$TMP/sessions/it-1.json" <<'EOF'
import json, sys
rec = json.load(open(sys.argv[1]))
assert rec["state"] == "idle", rec
assert rec.get("busySince") is None, rec
EOF
check "Stop -> idle, busySince cleared" $?

# 5. Malformed stdin: exit 0, no output, no file
OUT="$(echo 'not json at all' | "$BIN" PreToolUse 2>&1)"
CODE=$?
[[ "$CODE" -eq 0 && -z "$OUT" ]]; check "malformed stdin: silent exit 0" $?
[[ ! -e "$TMP/sessions/not" ]]; check "malformed stdin: no file written" $?

# 6. Missing argv event name: payload hook_event_name used instead
echo '{"session_id":"it-2","cwd":"/x","hook_event_name":"UserPromptSubmit"}' | "$BIN"
check "no argv: exits 0" $?
python3 - "$TMP/sessions/it-2.json" <<'EOF'
import json, sys
assert json.load(open(sys.argv[1]))["state"] == "thinking"
EOF
check "no argv: payload event name used" $?

# 7. Path-traversal session id: exit 0, nothing written outside sessions dir
echo '{"session_id":"../evil"}' | "$BIN" Stop
check "traversal id: exits 0" $?
[[ ! -e "$TMP/evil.json" ]]; check "traversal id: no file escapes sessions dir" $?

if [[ "$FAILURES" -gt 0 ]]; then echo "$FAILURES failure(s)"; exit 1; fi
echo "all hook integration tests passed"

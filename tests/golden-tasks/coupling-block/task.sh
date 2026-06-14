#!/usr/bin/env bash
# Golden task 2: coupling-enforcement core behavior.
REPO_ROOT="${REPO_ROOT:-/c/Users/v173617/Source_Code/code-forge}"

WORK="$(mktemp -d)"
cd "$WORK"
git init -q .
mkdir -p .preflight/gate

printf '%s' '[{"files":["Svc.cs","Other.cs"],"findings":["x"],"acknowledged":false}]' > .preflight/gate/active-groups.json

OUT=$(printf '%s' '{"tool_name":"Edit","tool_input":{"file_path":"Svc.cs","old_string":"a","new_string":"b"}}' | timeout 10 bash "$REPO_ROOT/hooks/coupled-edit-gate" 2>&1)
RC=$?

rm -rf "$WORK"

if [ "$RC" = "2" ]; then
  echo "Golden 2 PASS: unacknowledged coupling group blocked (exit 2)"
  exit 0
else
  echo "Golden 2 FAIL: expected exit 2, got $RC"
  exit 1
fi

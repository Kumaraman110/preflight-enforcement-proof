#!/usr/bin/env bash
# Golden task 1: forbidden-key detection in adjudication records.
REPO_ROOT="${REPO_ROOT:-/c/Users/v173617/Source_Code/code-forge}"

WORK="$(mktemp -d)"
cd "$WORK"
mkdir -p .preflight/adjudications

OUT=$(printf '%s' '{"tool_name":"Write","tool_input":{"file_path":".preflight/adjudications/verdict.json","content":"{\"adjudications\":[{\"commentId\":1,\"parentVerdict\":\"FIXED\",\"citedEvidence\":\"Foo.cs:12\",\"verifiedAgainstSource\":true}]}"}}' | timeout 10 bash "$REPO_ROOT/hooks/adjudication-output-gate" 2>&1)
RC=$?

rm -rf "$WORK"

if [ "$RC" = "2" ]; then
  echo "Golden 1 PASS: forbidden key blocked (exit 2)"
  exit 0
else
  echo "Golden 1 FAIL: expected exit 2, got $RC"
  exit 1
fi

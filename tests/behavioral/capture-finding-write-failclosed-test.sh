#!/usr/bin/env bash
# Behavioral test for the silent write-failure fail-open in lib/capture-finding.sh (G4).
#
# THE BUG (self-review G4): capture-finding.sh runs under `set -uo pipefail` (no `set -e`). If the capture
# WRITE fails — mkdir -p cannot create the destination dir, or the header/append redirect fails — the
# failure only goes to stderr; control STILL falls through to the success echo ("captured: ...") and
# `exit 0`. So a FAILED capture is reported as SUCCESS and the finding is SILENTLY LOST. This contradicts
# the file's own contract (header: "Exit: 0 = entry written"; "a defect is NEVER silently dropped") and
# defeats the sole caller's failure-detection (coverage-gap-detect.sh:209 keys off a non-zero exit that
# never comes). A lost capture is INVISIBLE — it looks identical to "no defect found", the exact
# accountability gap the framework exists to prevent.
#
# THE PRINCIPLE (this fix family): a capture that CANNOT verify it persisted the finding must FAIL CLOSED
# (error + non-zero exit), never report a silent success.
#
# RED->GREEN:
#   W1 — write fails (DEST parent is a regular FILE, so mkdir -p / the redirects fail):
#          RED  (pre-fix): exit 0 + "captured: ..." on stdout — silent loss (fail-open).
#          GREEN (post-fix): non-zero exit, an error naming the failed write, and NO "captured:" success.
#   W2 — regression: a NORMAL writable target still captures (exit 0, "captured:", file written).
#   W3 — regression: the existing usage error (missing --category) still exits 2 (unchanged).
#
# Exit 0 = all assertions passed; exit 1 = at least one failed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CAP="$ROOT/lib/capture-finding.sh"

PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }

[ -f "$CAP" ] || { bad "missing $CAP"; echo ""; echo "capture-finding-write-failclosed tests: ${PASS} passed, ${FAIL} failed"; exit 1; }

# ── W1 (RED->GREEN): an UNWRITABLE destination must FAIL CLOSED, not silently report success ──
RR="$(mktemp -d)/root"; mkdir -p "$RR"
( cd "$RR" && git init -q && git commit -q --allow-empty -m init ) >/dev/null 2>&1
# The default capture path is docs/review/checklist-additions.md. Make 'docs' a regular FILE so
# `mkdir -p .../docs/review` and the redirects into it MUST fail.
printf 'i am a file, not a directory\n' > "$RR/docs"
OUT="$(bash "$CAP" --source deploy --category "X" --summary "should fail to write" --repo-root "$RR" 2>&1)"; RC=$?
if [ "$RC" -ne 0 ] && ! printf '%s' "$OUT" | grep -q "^captured:"; then
  ok "W1: a FAILED capture write fails CLOSED (exit $RC != 0, no 'captured:' success) — finding not silently lost"
else
  bad "W1: FAIL-OPEN — failed write reported success (RC=$RC, OUT=$(printf '%s' "$OUT" | tr '\n' '|'))"
fi
# Stronger: the error must actually be surfaced (a diagnostic, not just a bare non-zero).
if printf '%s' "$OUT" | grep -qiE 'capture-finding:.*(write|create|directory|failed)'; then
  ok "W1b: the write failure is SURFACED with a capture-finding diagnostic (not a bare exit)"
else
  bad "W1b: no capture-finding write-failure diagnostic surfaced (OUT=$(printf '%s' "$OUT" | tr '\n' '|'))"
fi

# ── W2 (regression): a normal writable target still captures cleanly ──
WS="$(mktemp -d)/ws"; mkdir -p "$WS"
( cd "$WS" && git init -q && git commit -q --allow-empty -m init ) >/dev/null 2>&1
OUT="$(PREFLIGHT_CAPTURE_TS=2026-06-21T00:00:00Z bash "$CAP" \
  --source deploy --category "Null deref" --summary "deploy: NRE on 204" \
  --bucket checklist-additions --repo-root "$WS" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "^captured:" \
   && grep -q 'deploy: NRE on 204' "$WS/docs/review/checklist-additions.md" 2>/dev/null; then
  ok "W2 regression: a normal writable capture still succeeds (exit 0, 'captured:', entry on disk)"
else
  bad "W2 regression: normal capture broke (RC=$RC, OUT=$(printf '%s' "$OUT" | tr '\n' '|'))"
fi

# ── W3 (regression): the existing usage error (missing --category) still exits 2 ──
bash "$CAP" --source deploy --summary "no category" --repo-root "$WS" >/dev/null 2>&1
[ "$?" -eq 2 ] && ok "W3 regression: missing --category still exits 2 (usage error unchanged)" \
              || bad "W3 regression: missing --category should exit 2"

echo ""
echo "capture-finding-write-failclosed tests: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

#!/usr/bin/env bash
# Behavioral test for lib/rubric-resolve.sh — the Model B MERGE ENGINE (resolver). It takes a base
# rubric + tighten-only overlays and emits the EFFECTIVE merged rubric, REUSING lib/rubric-overlay-check.sh
# as a fail-closed merge gate. Design: .release-audit/RUBRIC-GOVERNANCE.md.
#
# THE LOAD-BEARING PROPERTY: a weakening overlay must ABORT the merge (nothing emitted), never be silently
# dropped while the rest proceeds. A valid tighten overlay must produce a correct effective rubric: base
# rules verbatim, shared §IDs raised to the strictest severity, overlay-added rules appended.
#
# Proves:
#   M1 GREEN — base + tighten overlay → merge OK (exit 0); effective has the RAISED base severity AND the
#              overlay-ADDED rule; the untouched base rule keeps its severity.
#   M2 GREEN — base alone (no overlays) → emits the base, both base rules present (exit 0).
#   M3 RED   — base + weakening overlay (lowers a base severity) → MERGE ABORTED (exit 2), nothing on
#              stdout, names the offending §ID. (Does NOT silently drop the weakening.)
#   M4 RED   — base + a REMOVE-directive overlay → ABORTED (exit 2).
#   M5       — multi-overlay: base + two valid tighten overlays → both sets of additions present, strictest
#              severity wins for a shared raise.
#   M6       — REUSE check: the resolver actually invokes lib/rubric-overlay-check.sh (not a reimplemented
#              copy of the no-weaken logic) — proven by behavior (M3/M4 block) + a structural source check.
#   U1       — usage / missing base → exit 2.
#
# Exit 0 = all assertions passed; exit 1 = at least one failed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RESOLVE="$ROOT/lib/rubric-resolve.sh"
CHECK="$ROOT/lib/rubric-overlay-check.sh"
POC="$ROOT/examples/rubrics/governance-poc"
BASE="$POC/base-rubric.md"

PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }

if [ ! -f "$RESOLVE" ]; then
  bad "resolver not found at $RESOLVE"; echo ""; echo "rubric-resolve tests: ${PASS} passed, ${FAIL} failed"; exit 1
fi
PYOK=0
for c in python3 python; do command -v "$c" &>/dev/null && "$c" -c "pass" &>/dev/null 2>&1 && PYOK=1 && break; done
if [ "$PYOK" -eq 0 ]; then
  echo "SKIP: no working python — rubric-resolve needs python to parse/merge rubrics"
  echo ""; echo "rubric-resolve tests: ${PASS} passed, ${FAIL} failed (skipped: no python)"; exit 0
fi
if [ ! -f "$BASE" ]; then
  bad "POC base rubric not found at $BASE"; echo ""; echo "rubric-resolve tests: ${PASS} passed, ${FAIL} failed"; exit 1
fi

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# grep -a everywhere: the rubric text contains the multibyte '§' (0xC2 0xA7) which makes grep treat the
# stream as binary otherwise.

# ── M1: base + the committed tighten overlay → effective rubric ──
OUT="$T/m1.md"
bash "$RESOLVE" "$BASE" "$POC/overlay-tighten.md" > "$OUT" 2>"$T/m1.err"; RC=$?
if [ "$RC" = "0" ]; then
  # Extractor note: trigger on the bare '<id>.<n>' substring, NOT '^### .*<id>' — an awk '.*' that spans
  # the multibyte '§' (0xC2 0xA7) before the id fails to match on this Git-Bash awk. The bare substring is
  # reliable. §B1.1 was major in base; the tighten overlay raises it to blocker → effective shows blocker.
  B11_SEV="$(awk '/B1\.1/{p=1} p&&/^\*\*Severity:/{print;exit}' "$OUT" | grep -ao 'blocker\|major\|minor\|info' | head -1)"
  # §B2.1 untouched by the overlay → stays major.
  B21_SEV="$(awk '/B2\.1/{p=1} p&&/^\*\*Severity:/{print;exit}' "$OUT" | grep -ao 'blocker\|major\|minor\|info' | head -1)"
  HAS_ADDED="$(grep -ac 'T1\.1' "$OUT")"
  if [ "$B11_SEV" = "blocker" ] && [ "$B21_SEV" = "major" ] && [ "$HAS_ADDED" -ge 1 ]; then
    ok "M1 GREEN: tighten merge — §B1.1 raised major→blocker, §B2.1 stays major, overlay-added §T1.1 present"
  else
    bad "M1: effective rubric wrong — B1.1=$B11_SEV (want blocker), B2.1=$B21_SEV (want major), added-T1.1=$HAS_ADDED (want ≥1)"
  fi
else
  bad "M1: tighten merge should succeed (exit 0), got $RC; stderr: $(cat "$T/m1.err")"
fi

# ── M2: base alone → emits the base unchanged ──
OUT="$T/m2.md"
bash "$RESOLVE" "$BASE" > "$OUT" 2>/dev/null; RC=$?
NBASE="$(grep -ac '^### ' "$OUT")"
[ "$RC" = "0" ] && [ "$NBASE" -ge 2 ] && ok "M2 GREEN: base alone (no overlays) → emitted, $NBASE base rules present (exit 0)" \
  || bad "M2: base-only resolve should exit 0 with ≥2 rules, got exit $RC, $NBASE rules"

# ── M3: base + weakening overlay → MERGE ABORTED, nothing on stdout, names the §ID ──
OUT="$T/m3.md"
bash "$RESOLVE" "$BASE" "$POC/overlay-weaken.md" > "$OUT" 2>"$T/m3.err"; RC=$?
STDOUT_BYTES="$(wc -c < "$OUT" | tr -d ' ')"
if [ "$RC" = "2" ] && [ "$STDOUT_BYTES" = "0" ]; then
  if grep -aq 'B2\.1' "$T/m3.err"; then
    ok "M3 RED: weakening overlay → MERGE ABORTED (exit 2), 0 bytes on stdout, names §B2.1 — weakening NOT silently dropped"
  else
    bad "M3: aborted with empty stdout but did not name the offending §ID in stderr"
  fi
else
  bad "M3: weakening overlay MUST abort (exit 2, 0 stdout bytes), got exit $RC, $STDOUT_BYTES bytes — A SILENT-WEAKENING MERGE WOULD BE A SAFETY HOLE"
fi

# ── M4: base + an explicit REMOVE-directive overlay → ABORTED ──
cat > "$T/remove.md" <<'EOF'
## §B2 Input Validation
REMOVE §B2.1 — our team gets too many false positives.
EOF
OUT="$T/m4.md"
bash "$RESOLVE" "$BASE" "$T/remove.md" > "$OUT" 2>/dev/null; RC=$?
STDOUT_BYTES="$(wc -c < "$OUT" | tr -d ' ')"
[ "$RC" = "2" ] && [ "$STDOUT_BYTES" = "0" ] && ok "M4 RED: REMOVE-directive overlay → ABORTED (exit 2, nothing emitted)" \
  || bad "M4: REMOVE-directive overlay should abort (exit 2, 0 bytes), got exit $RC, $STDOUT_BYTES bytes"

# ── M5: multi-overlay — base + tighten + a second add-only overlay → both additions present ──
cat > "$T/overlay2.md" <<'EOF'
## §T9 Team Rate Limiting
### §T9.1 Missing per-tenant rate limit
**Detect:** Public endpoint without a per-tenant rate limit.
**Severity:** major
**Fix:** Add a per-tenant limiter.
EOF
OUT="$T/m5.md"
bash "$RESOLVE" "$BASE" "$POC/overlay-tighten.md" "$T/overlay2.md" > "$OUT" 2>"$T/m5.err"; RC=$?
if [ "$RC" = "0" ] && [ "$(grep -ac 'T1\.1' "$OUT")" -ge 1 ] && [ "$(grep -ac 'T9\.1' "$OUT")" -ge 1 ]; then
  B11_SEV="$(awk '/B1\.1/{p=1} p&&/^\*\*Severity:/{print;exit}' "$OUT" | grep -ao 'blocker\|major\|minor\|info' | head -1)"
  [ "$B11_SEV" = "blocker" ] && ok "M5: multi-overlay — both §T1.1 and §T9.1 present, strictest raise (§B1.1=blocker) applied" \
    || bad "M5: multi-overlay merged both rules but raise not applied (B1.1=$B11_SEV)"
else
  bad "M5: multi-overlay should merge both additions (exit 0), got exit $RC; T1.1=$(grep -ac 'T1\.1' "$OUT") T9.1=$(grep -ac 'T9\.1' "$OUT")"
fi

# ── M6: REUSE — the resolver invokes lib/rubric-overlay-check.sh, not a reimplemented copy ──
# Behavior already proves the gate fires (M3/M4). Structural: the resolver references the shared check by
# name and does NOT contain its own RANK/weakening logic.
if grep -q 'rubric-overlay-check.sh' "$RESOLVE" && ! grep -q 'LOWERS severity' "$RESOLVE"; then
  ok "M6: resolver REUSES lib/rubric-overlay-check.sh as the merge gate (references it; no reimplemented no-weaken logic)"
else
  bad "M6: resolver should call rubric-overlay-check.sh and NOT reimplement the weakening logic"
fi

# ── U1: usage error ──
bash "$RESOLVE" > /dev/null 2>&1; [ "$?" = "2" ] && ok "U1: missing base arg → exit 2" || bad "U1: missing base should exit 2"
bash "$RESOLVE" "/nonexistent/base.md" > /dev/null 2>&1; [ "$?" = "2" ] && ok "U1b: nonexistent base → exit 2" || bad "U1b: nonexistent base should exit 2"

echo ""
echo "rubric-resolve tests: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

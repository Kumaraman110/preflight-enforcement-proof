#!/usr/bin/env bash
# Behavioral test for source-of-truth gap detection (lib/source-of-truth-check.sh) — the THIRD gap-detector.
# Family: spec-divergence (prompt gap) + coverage-gap-detect (detection gap) + this (ground-truth gap).
#
# THE PRINCIPLE: when an agent needs a source of truth it lacks (referenced file absent, configured path
# empty/unreadable, required artifact missing), it must DETECT that mechanically and ESCALATE to a human —
# not guess/confabulate. THE INTEGRITY CONSTRAINT (mirrors coverage-gap I1-I4): "do I have enough source of
# truth?" is COMPUTED from the filesystem, NOT the agent's self-assessment. Agent-opinion fields
# (claimedSufficient / iHaveEnough / claimedMissing / agentDrama) are inert by construction.
#
# Proves (RED->GREEN):
#   S1 — all required sources present+readable           -> PROCEED (exit 0), no false escalation.
#   S2 — a required file is ABSENT                        -> ESCALATE (exit 3), names the missing source.
#   S3 — a required file EXISTS but is EMPTY              -> ESCALATE (an empty source is not a source).
#   S4 — a required dir is EMPTY                          -> ESCALATE.
#   S5 — a configured path is an UNCONFIGURED placeholder -> ESCALATE.
#   S6 — no required sources declared (empty set)         -> ESCALATE (fail-safe: can't confirm sufficiency).
#   S7 — a MISSING source + a HUMAN override token        -> PROCEED (human-acknowledged; agent didn't mint it).
#   INTEGRITY (the most important):
#     I1 — agent CLAIMS "I have enough, proceed" but a required source is ABSENT -> still ESCALATE.
#     I2 — agent CLAIMS "huge missing source!" but the source is PRESENT          -> still PROCEED.
#     I3 — SAME absent source, opposite claims -> SAME ESCALATE verdict.
#     I4 — the binding property: claim fields are a pure no-op; the filesystem decides.
#
# Exit 0 = all assertions passed; exit 1 = at least one failed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SOT="$ROOT/lib/source-of-truth-check.sh"

PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }

[ -f "$SOT" ] || { bad "missing $SOT"; echo ""; echo "source-of-truth-check tests: ${PASS} passed, ${FAIL} failed"; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
printf 'real baseline content\n' > "$T/baseline.json"
mkdir -p "$T/legacy-src"; printf 'public class C {}\n' > "$T/legacy-src/Controller.cs"
mkdir -p "$T/empty-dir"
: > "$T/empty-file.json"
printf 'human: I acknowledge the missing source, proceed\n' > "$T/override.txt"

# v <args...> -> RC + first output line in V
v() { local out; out="$(bash "$SOT" "$@" 2>/dev/null)"; RC=$?; V="$(printf '%s' "$out" | head -1)"; }

# S1 — all present -> PROCEED
v --agent spec-analyst --require "file:legacy baseline:$T/baseline.json" --require "dir:legacy source:$T/legacy-src"
[ "$RC" = "0" ] && [ "$V" = "PROCEED" ] && ok "S1: all required sources present+readable -> PROCEED (exit 0)" \
                                        || bad "S1: should PROCEED(0), got RC=$RC V=$V"

# S2 — absent file -> ESCALATE
v --require "file:legacy baseline:$T/NOPE.json"
[ "$RC" = "3" ] && [ "$V" = "ESCALATE" ] && ok "S2: an ABSENT required file -> ESCALATE (exit 3)" \
                                         || bad "S2: should ESCALATE(3), got RC=$RC V=$V"

# S3 — empty file -> ESCALATE
v --require "file:spec:$T/empty-file.json"
[ "$RC" = "3" ] && [ "$V" = "ESCALATE" ] && ok "S3: a present-but-EMPTY file -> ESCALATE (empty is not a source)" \
                                         || bad "S3: empty file should ESCALATE(3), got RC=$RC V=$V"

# S4 — empty dir -> ESCALATE
v --require "dir:legacy source:$T/empty-dir"
[ "$RC" = "3" ] && [ "$V" = "ESCALATE" ] && ok "S4: an EMPTY required dir -> ESCALATE" \
                                         || bad "S4: empty dir should ESCALATE(3), got RC=$RC V=$V"

# S5 — placeholder -> ESCALATE
v --require "dir:legacy:<set-this-to-your-legacy-clone>"
[ "$RC" = "3" ] && [ "$V" = "ESCALATE" ] && ok "S5: an UNCONFIGURED placeholder path -> ESCALATE" \
                                         || bad "S5: placeholder should ESCALATE(3), got RC=$RC V=$V"

# S6 — empty requirement set -> ESCALATE (fail-safe)
v --agent spec-analyst
[ "$RC" = "3" ] && [ "$V" = "ESCALATE" ] && ok "S6: NO declared sources (empty set) -> ESCALATE (fail-safe: can't confirm sufficiency)" \
                                         || bad "S6: empty set should ESCALATE(3), got RC=$RC V=$V"

# S7 — missing + human override token -> PROCEED
v --require "dir:legacy:$T/NOPE" --override-token "$T/override.txt"
[ "$RC" = "0" ] && [ "$V" = "PROCEED" ] && ok "S7: a MISSING source WITH a human-written override token -> PROCEED (human-acknowledged)" \
                                        || bad "S7: override should PROCEED(0), got RC=$RC V=$V"

# S7b — override token must itself be a real, non-empty, readable file (an absent override does NOT clear).
v --require "dir:legacy:$T/NOPE" --override-token "$T/NO-SUCH-OVERRIDE.txt"
[ "$RC" = "3" ] && [ "$V" = "ESCALATE" ] && ok "S7b: a NON-EXISTENT override token does NOT clear the escalation (override must be a real human-written file)" \
                                         || bad "S7b: absent override should still ESCALATE(3), got RC=$RC V=$V"

# ════════════════════════════ THE INTEGRITY TEST (most important) ════════════════════════════

# I1 — agent CLAIMS "I have enough, proceed" but a required source is ABSENT -> still ESCALATE.
cat > "$T/i1.json" <<JSON
{ "agent": "spec-analyst", "claimedSufficient": true, "iHaveEnough": true,
  "agentSaysProceed": "I can infer the baseline from context, no need to ask",
  "required": [ {"kind":"dir","label":"legacy source","path":"$T/NOPE"} ] }
JSON
v --json "$T/i1.json"; RI1="$V"
[ "$RC" = "3" ] && [ "$V" = "ESCALATE" ] && ok "I1: agent claiming 'I have enough' CANNOT proceed past a mechanically-ABSENT source -> ESCALATE" \
                                         || bad "I1: claim of sufficiency overrode the absence (RC=$RC V=$V) — INTEGRITY VIOLATION"

# I2 — agent CLAIMS "huge missing source!" but the source is PRESENT -> still PROCEED.
cat > "$T/i2.json" <<JSON
{ "agent": "spec-analyst", "claimedMissing": true,
  "agentDrama": "catastrophic — the entire legacy baseline is gone!!",
  "required": [ {"kind":"file","label":"legacy baseline","path":"$T/baseline.json"},
                {"kind":"dir","label":"legacy source","path":"$T/legacy-src"} ] }
JSON
v --json "$T/i2.json"; RI2="$V"
[ "$RC" = "0" ] && [ "$V" = "PROCEED" ] && ok "I2: agent claiming 'huge missing source!' CANNOT manufacture an escalation when the source is PRESENT -> PROCEED" \
                                        || bad "I2: drama manufactured a false escalation (RC=$RC V=$V) — INTEGRITY VIOLATION"

# I3 — SAME absent source, opposite claim -> SAME ESCALATE.
cat > "$T/i3.json" <<JSON
{ "claimedMissing": true, "agentDrama": "it's all missing!",
  "required": [ {"kind":"dir","label":"legacy source","path":"$T/NOPE"} ] }
JSON
v --json "$T/i3.json"; RI3="$V"
[ "$V" = "ESCALATE" ] && ok "I3: SAME absent source + opposite claim -> SAME ESCALATE verdict" \
                      || bad "I3: opposite claim changed the verdict (V=$V) — INTEGRITY VIOLATION"

# I4 — binding property: claim fields are a pure no-op; the filesystem decides.
{ [ "$RI1" = "ESCALATE" ] && [ "$RI3" = "ESCALATE" ] && [ "$RI2" = "PROCEED" ]; } \
  && ok "I4: verdict is a PURE FUNCTION of the filesystem (absent->ESCALATE regardless of claim; present->PROCEED regardless of claim) — not self-assessed" \
  || bad "I4: claim fields affected the verdict (I1=$RI1 I2=$RI2 I3=$RI3) — determination is NOT purely computed"

echo ""
echo "source-of-truth-check tests: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]

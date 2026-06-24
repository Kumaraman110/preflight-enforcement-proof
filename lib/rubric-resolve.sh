#!/usr/bin/env bash
# rubric-resolve.sh — Model B rubric MERGE ENGINE (the resolver). Takes a shared BASE rubric + zero or
# more team TIGHTEN-ONLY overlays and emits the EFFECTIVE merged rubric that code-reviewer WOULD load.
#
# ┌──────────────────────────────────────────────────────────────────────────────────────────────┐
# │ STAGED, NOT WIRED LIVE. This resolver is a standalone, fully-tested component. It is NOT wired  │
# │ into code-reviewer's runtime rubric-load path — that is a separate owner-reviewed step (see the  │
# │ "WIRE-HERE" integration note at the bottom of this file). Like behavioral-contract-gate before   │
# │ it was wired, this awaits an owner decision before going live.                                  │
# └──────────────────────────────────────────────────────────────────────────────────────────────┘
#
# THE MODEL (see .release-audit/RUBRIC-GOVERNANCE.md, Model B):
#   - The BASE rubric is the shared detection FLOOR every team inherits.
#   - A team OVERLAY may ONLY TIGHTEN: ADD a new rule (new §ID) or RAISE a base rule's severity. It may
#     NEVER weaken the base (remove a base rule, lower a base severity, or redefine a base Detect).
#   - The EFFECTIVE rubric = base, with each overlay's additions appended and each shared §ID's severity
#     raised to the strictest (max-rank) any layer specifies. Base Detect text is immutable.
#
# FAIL-CLOSED MERGE GATE (the load-bearing property): before merging an overlay, this resolver runs the
# PROVEN POC check `lib/rubric-overlay-check.sh` (REUSED, not reimplemented). If ANY overlay weakens the
# base, the merge ABORTS (exit 2) — it does NOT silently drop the weakening and proceed. A merge can only
# emit an effective rubric whose floor is >= the base's, for every base rule.
#
# Usage:
#   bash lib/rubric-resolve.sh <base-rubric.md> [overlay1.md overlay2.md ...]
#     With zero overlays, emits the base unchanged (the degenerate-but-valid case).
#     Emits the effective merged rubric to STDOUT.
#
# Exit: 0 = merged OK (effective rubric on stdout) · 1 = (reserved) · 2 = a weakening overlay was
#       rejected, or usage / parse error (reason on stderr; NOTHING emitted to stdout on a rejected merge).
#
# HONESTY LABEL: the no-weaken guarantee is exactly the overlay-check's guarantee — structural
# (rule-removal, severity-lowering, base-Detect redefinition caught robustly); it does NOT NLP-judge free
# prose an overlay adds to its OWN new rules (out of scope by construction — the base rule is immutable
# from the overlay's side). Base-file changes are governed separately (base-owners CODEOWNERS), not here.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OVERLAY_CHECK="$SCRIPT_DIR/rubric-overlay-check.sh"

BASE="${1:-}"
if [ -z "$BASE" ]; then
  echo "Usage: $0 <base-rubric.md> [overlay1.md overlay2.md ...]" >&2
  exit 2
fi
shift || true
OVERLAYS=("$@")

[ -f "$BASE" ] || { echo "ERROR: base rubric not found: $BASE" >&2; exit 2; }
[ -f "$OVERLAY_CHECK" ] || { echo "ERROR: overlay-check engine not found at $OVERLAY_CHECK (the resolver reuses it as the merge gate)." >&2; exit 2; }

PYTHON_CMD=""
for c in python3 python; do
  if command -v "$c" &>/dev/null && "$c" -c "pass" &>/dev/null 2>&1; then PYTHON_CMD="$c"; break; fi
done
[ -n "$PYTHON_CMD" ] || { echo "ERROR: rubric-resolve needs a working python interpreter." >&2; exit 2; }

# ── Step 1: GATE every overlay through the PROVEN overlay-check (REUSE, do not reimplement) ───────────
# A single weakening overlay aborts the whole merge — fail closed, emit nothing to stdout.
for ov in "${OVERLAYS[@]}"; do
  [ -f "$ov" ] || { echo "ERROR: overlay not found: $ov" >&2; exit 2; }
  # Capture the overlay-check's REAL exit code (run it, then read $? — do NOT use `if ! cmd; then rc=$?`,
  # which captures the NEGATED status and always reports 0). set -e is off, so a non-zero won't abort here.
  bash "$OVERLAY_CHECK" "$BASE" "$ov" >/dev/null 2>"$SCRIPT_DIR/.resolve-overlay-err.$$"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "MERGE ABORTED: overlay '$ov' is rejected by the no-weaken check (it would weaken the base floor)." >&2
    sed 's/^/  /' "$SCRIPT_DIR/.resolve-overlay-err.$$" >&2 2>/dev/null || true
    rm -f "$SCRIPT_DIR/.resolve-overlay-err.$$" 2>/dev/null || true
    # Map overlay-check's "1=weaken / 2=usage/parse" both to resolver exit 2 (merge could not be produced).
    echo "  (overlay-check exit $rc; the merge does NOT silently drop the weakening — nothing emitted.)" >&2
    exit 2
  fi
  rm -f "$SCRIPT_DIR/.resolve-overlay-err.$$" 2>/dev/null || true
done

# ── Step 2: All overlays tighten-only — produce the EFFECTIVE merged rubric ───────────────────────────
# The merge is deterministic: base rules verbatim (Detect immutable), severities raised to the strictest
# any layer specifies for a shared §ID, and overlay-added rules (new §IDs) appended. Python does the parse
# + merge over the same uniform schema the overlay-check parses (### §<id> + **Severity:** + **Detect:**).
# Pass base + overlays as ARGV (not a newline-joined env var). On this Git-Bash/MSYS setup, argv paths get
# MSYS→Windows path translation reliably (so native python can open a /tmp/... path), whereas a path read
# back out of a newline-joined env value does NOT get translated and fails to open. argv is the robust seam.
"$PYTHON_CMD" - "$BASE" "${OVERLAYS[@]+"${OVERLAYS[@]}"}" <<'PYEOF'
import os, re, sys

RANK = {"blocker": 3, "major": 2, "minor": 1, "info": 0}
INV_RANK = {v: k for k, v in RANK.items()}

def parse_blocks(path):
    """Parse a rubric .md into an ordered list of rule blocks. Each block:
       {id, sev, sev_rank, lines:[raw lines of the whole '### §id ...' block]}.
       A block runs from a '### §<id>' heading to (but not including) the next '### ' heading or EOF.
       Also returns the PREAMBLE (everything before the first ### block) so headers/comments survive."""
    blocks = []
    preamble = []
    cur = None
    with open(path, "r", encoding="utf-8") as f:
        for raw in f:
            line = raw.rstrip("\n")
            m = re.match(r'^###\s+(§\S+)', line)
            if m:
                if cur is not None:
                    blocks.append(cur)
                cur = {"id": m.group(1), "sev": None, "sev_rank": -1, "lines": [line]}
                continue
            if cur is None:
                preamble.append(line)
                continue
            cur["lines"].append(line)
            sev = re.match(r'^\*\*Severity:\*\*\s*(\w+)', line)
            if sev and cur["sev"] is None:
                s = sev.group(1).strip().lower()
                cur["sev"] = s
                cur["sev_rank"] = RANK.get(s, -1)
    if cur is not None:
        blocks.append(cur)
    return preamble, blocks

base_path = sys.argv[1]
overlays = [p for p in sys.argv[2:] if p.strip()]

base_pre, base_blocks = parse_blocks(base_path)
base_by_id = {b["id"]: b for b in base_blocks}

# Raised severities for shared §IDs (id -> max rank seen across overlays, only if > base rank).
raised = {}          # id -> (new_rank, source_overlay)
added = []           # list of (block, source_overlay) for brand-new §IDs, in encounter order
seen_added = set()

for ov in overlays:
    _, ov_blocks = parse_blocks(ov)
    for b in ov_blocks:
        if b["id"] in base_by_id:
            # shared id — overlay may only have RAISED severity (the overlay-check already guaranteed
            # it did not lower or redefine Detect). Apply the strictest severity any layer specifies.
            base_rank = base_by_id[b["id"]]["sev_rank"]
            if b["sev_rank"] > base_rank and b["sev_rank"] > raised.get(b["id"], (base_rank,))[0]:
                raised[b["id"]] = (b["sev_rank"], ov)
        else:
            # brand-new rule — additive. First overlay to introduce a given new §ID wins its block.
            if b["id"] not in seen_added:
                seen_added.add(b["id"])
                added.append((b, ov))

# ── Emit the EFFECTIVE merged rubric ──
out = []
out.append("<!-- ============================================================================ -->")
out.append("<!-- EFFECTIVE MERGED RUBRIC — generated by lib/rubric-resolve.sh (Model B).        -->")
out.append("<!-- base + tighten-only overlays. DO NOT EDIT BY HAND: edit the base or an overlay  -->")
out.append("<!-- and re-resolve. Severities shown are the strictest any layer specifies; base    -->")
out.append("<!-- Detect text is verbatim from the base (overlays cannot alter it).               -->")
out.append("<!-- ============================================================================ -->")
out.append("")

# Base preamble (the base file's header/comment lines) first.
for ln in base_pre:
    out.append(ln)

# Base blocks in order, with any raised severity applied (and an audit comment noting the raise).
for b in base_blocks:
    if b["id"] in raised:
        new_rank, src = raised[b["id"]]
        new_sev = INV_RANK[new_rank]
        for ln in b["lines"]:
            if re.match(r'^\*\*Severity:\*\*', ln):
                out.append(f"**Severity:** {new_sev}")
                out.append(f"<!-- severity RAISED from {b['sev']} to {new_sev} by overlay: {os.path.basename(src)} (tighten) -->")
            else:
                out.append(ln)
    else:
        out.extend(b["lines"])
    out.append("")

# Overlay-added rules appended under a clearly-labelled section.
if added:
    out.append("<!-- ===== OVERLAY-ADDED RULES (new §IDs not in base; additive, tighten) ===== -->")
    out.append("")
    for b, src in added:
        out.append(f"<!-- added by overlay: {os.path.basename(src)} -->")
        out.extend(b["lines"])
        out.append("")

sys.stdout.write("\n".join(out).rstrip("\n") + "\n")
PYEOF
RC=$?
exit $RC

# ╔══════════════════════════════════════════════════════════════════════════════════════════════╗
# ║ WIRE-HERE — INTEGRATION POINT (AWAITING OWNER WIRING DECISION)                                  ║
# ╠══════════════════════════════════════════════════════════════════════════════════════════════╣
# ║ code-reviewer (agents/code-reviewer.md, "Rubric Discovery", lines 17-32) currently loads the    ║
# ║ rubric DIRECTLY from config's `rubric` field (string path, or array of paths read as-is). There ║
# ║ is no merge step — a `rubric` array is walked file-by-file, not merged into an effective floor.  ║
# ║                                                                                                  ║
# ║ TO WIRE THIS RESOLVER LIVE (the owner-reviewed step, NOT done here):                             ║
# ║   1. Add a config shape for layered rubrics, e.g.                                               ║
# ║        "rubric": { "base": "examples/rubrics/rubric-generic-dotnet.md",                          ║
# ║                    "overlays": ["rubrics/team-payments-overlay.md", ...] }                       ║
# ║      (keep the existing string / array forms working — this is an ADDITIVE third shape).         ║
# ║   2. In code-reviewer.md "Rubric Discovery" step 2, when `rubric` is the layered object:         ║
# ║        run `bash ${FRAMEWORK_ROOT}/lib/rubric-resolve.sh <base> <overlays...>` and review        ║
# ║        against its STDOUT (the effective rubric) instead of reading the files raw.               ║
# ║   3. FAIL-CLOSED on a non-zero resolver exit: if the resolver exits 2 (a weakening overlay), the ║
# ║      reviewer MUST report Overall: ERROR ("rubric merge rejected a weakening overlay — <reason>")║
# ║      and NOT fall back to the un-merged base or to reviewing nothing. A merge that can't be      ║
# ║      produced safely means the rubric set is mis-governed; that is a stop condition, not a       ║
# ║      degrade-to-base.                                                                            ║
# ║                                                                                                  ║
# ║ HOW TO VERIFY ONCE WIRED (the behavioral test the owner should require before trusting it live): ║
# ║   - Point a test config's layered `rubric` at base + a valid tighten overlay; run code-reviewer; ║
# ║     confirm a finding cites an overlay-ADDED §ID and a RAISED base severity is applied.          ║
# ║   - Point it at base + a weakening overlay; confirm code-reviewer reports ERROR (merge rejected),║
# ║     NOT a silent review against the un-weakened base (which would hide the mis-governance).      ║
# ║   - Add a tests/behavioral suite that drives code-reviewer's resolved-rubric path end to end.    ║
# ║                                                                                                  ║
# ║ Until wired: code-reviewer's live behavior is UNCHANGED. This resolver is provably correct as a  ║
# ║ standalone (tests/behavioral/rubric-resolve-test.sh) but is NOT proven in code-reviewer's actual ║
# ║ load path, because that path does not call it yet.                                              ║
# ╚══════════════════════════════════════════════════════════════════════════════════════════════╝

#!/usr/bin/env bash
# rubric-overlay-check.sh — enforce that a team rubric OVERLAY can only TIGHTEN the shared base,
# never WEAKEN it. The load-bearing mechanism of Model B (see .release-audit/RUBRIC-GOVERNANCE.md).
#
# A rubric is detection logic that feeds gates. Multi-team editing is a SAFETY problem: the risk is
# one team silently weakening a rule another team's service depends on. This check makes the BASE an
# immutable detection FLOOR that an overlay cannot lower — mechanism, not convention. It mirrors
# lib/config-overlay.sh's "can't weaken the committed value" pattern, applied to rubric rules.
#
# Usage:
#   bash lib/rubric-overlay-check.sh <base-rubric.md> <team-overlay.md>
#
# Model:
#   - An overlay is ADDITIVE. It lists ONLY the rules it adds or strengthens. A base rule the overlay
#     does NOT mention is inherited unchanged (fine). Removal is UNREPRESENTABLE in an additive overlay
#     — that is the strongest form of "can't remove a base rule".
#   - For any rule the overlay shares with the base (same §ID), the overlay is ALLOWED only if it
#     RAISES or keeps the severity (never lowers) AND keeps the base rule's Detect byte-identical
#     (an overlay must not redefine/narrow a base rule's Detect — it adds rules, it doesn't edit base
#     ones). A new §ID (not in base) is unrestricted (adding detection).
#   - An explicit removal/weaken directive in the overlay (a line matching REMOVE/DELETE/DISABLE/
#     LOOSEN/strikethrough of a base §ID) is BLOCKED outright.
#
# Severity rank: blocker(3) > major(2) > minor(1) > info(0). "Tighten" = overlay rank >= base rank.
#
# Exit: 0 = overlay only tightens (ALLOWED) · 1 = overlay weakens the base (BLOCKED, reason on stderr)
#       · 2 = usage / could-not-parse.
#
# HONESTY LABEL: this catches the STRUCTURAL weakenings robustly — removing a base rule, lowering a
# base severity, redefining a base Detect. It does NOT NLP-judge whether free prose an overlay adds to
# its OWN new rules is "really" strict (it cannot weaken the base — the base rule is immutable from the
# overlay's side — so that is out of scope by construction). Changes to the BASE file itself are
# governed separately (base-owners CODEOWNERS), not by this check.

set -uo pipefail

BASE="${1:-}"
OVERLAY="${2:-}"

if [ -z "$BASE" ] || [ -z "$OVERLAY" ]; then
  echo "Usage: $0 <base-rubric.md> <team-overlay.md>" >&2
  exit 2
fi
[ -f "$BASE" ]    || { echo "ERROR: base rubric not found: $BASE" >&2; exit 2; }
[ -f "$OVERLAY" ] || { echo "ERROR: overlay not found: $OVERLAY" >&2; exit 2; }

PYTHON_CMD=""
for c in python3 python; do
  if command -v "$c" &>/dev/null && "$c" -c "pass" &>/dev/null 2>&1; then PYTHON_CMD="$c"; break; fi
done
[ -n "$PYTHON_CMD" ] || { echo "ERROR: rubric-overlay-check needs a working python interpreter." >&2; exit 2; }

BASE="$BASE" OVERLAY="$OVERLAY" "$PYTHON_CMD" - <<'PYEOF'
import os, re, sys

RANK = {"blocker": 3, "major": 2, "minor": 1, "info": 0}

def parse_rules(path):
    """Parse a rubric .md into {section_id: {'severity': str, 'detect': str}}.
    A rule is a '### §<id> <title>' heading followed by a '**Severity:**' and '**Detect:**' line.
    Comments (<!-- ... -->) and prose are ignored. Uniform schema, verified across the real rubrics."""
    rules = {}
    cur = None
    with open(path, "r", encoding="utf-8") as f:
        for raw in f:
            line = raw.rstrip("\n")
            m = re.match(r'^###\s+(§\S+)', line)
            if m:
                cur = m.group(1)
                rules[cur] = {"severity": None, "detect": None}
                continue
            if cur is None:
                continue
            sev = re.match(r'^\*\*Severity:\*\*\s*(\w+)', line)
            if sev:
                rules[cur]["severity"] = sev.group(1).strip().lower()
                continue
            det = re.match(r'^\*\*Detect:\*\*\s*(.+)$', line)
            if det:
                rules[cur]["detect"] = det.group(1).strip()
                continue
    return rules

def find_removal_directives(path, base_ids):
    """Block an explicit removal/weaken directive naming a base §ID (a LOOSEN that tries to delete a
    base rule, or a strikethrough). Additive overlays should never contain these."""
    hits = []
    pat = re.compile(r'\b(REMOVE|DELETE|DISABLE|LOOSEN|DROP)\b.*?(§\S+)', re.IGNORECASE)
    strike = re.compile(r'~~\s*(§\S+)')
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            for m in pat.finditer(line):
                sid = m.group(2).rstrip('.,)')
                if sid in base_ids:
                    hits.append((sid, line.strip()))
            for m in strike.finditer(line):
                sid = m.group(1).rstrip('.,)')
                if sid in base_ids:
                    hits.append((sid, line.strip()))
    return hits

base = parse_rules(os.environ["BASE"])
overlay = parse_rules(os.environ["OVERLAY"])
base_ids = set(base)

violations = []

# (1) Explicit removal/weaken directive against a base rule.
for sid, line in find_removal_directives(os.environ["OVERLAY"], base_ids):
    violations.append(f"{sid}: overlay contains a removal/weaken directive against a base rule "
                      f"(\"{line[:80]}\") — an overlay cannot remove or disable a base rule.")

# (2) For every overlay rule that shares a §ID with the base: severity must not drop; Detect must match.
for sid, o in overlay.items():
    if sid not in base:
        continue  # new rule — unrestricted (adding detection)
    b = base[sid]
    bsev, osev = b.get("severity"), o.get("severity")
    if osev is None:
        violations.append(f"{sid}: overlay redefines a base rule but omits **Severity:** — cannot verify it does not weaken; blocked.")
    elif RANK.get(osev, -1) < RANK.get(bsev, 99):
        violations.append(f"{sid}: overlay LOWERS severity {bsev} -> {osev} — weakening the base detection floor. Blocked.")
    # Detect must be byte-identical: an overlay must not redefine/narrow a base rule's Detect.
    if o.get("detect") is not None and b.get("detect") is not None and o["detect"] != b["detect"]:
        violations.append(f"{sid}: overlay REDEFINES the base rule's Detect (narrowing/broadening scope is weakening). "
                          f"An overlay adds rules or raises severity; it does not edit base Detect. Blocked.")

print(f"base rules: {len(base)} ({', '.join(sorted(base_ids))})")
print(f"overlay rules: {len(overlay)} ({', '.join(sorted(overlay))})")
new_ids = sorted(set(overlay) - base_ids)
raised = [sid for sid in overlay if sid in base and RANK.get(overlay[sid].get('severity'),-1) > RANK.get(base[sid].get('severity'),-1)]
if new_ids: print(f"  overlay ADDS: {', '.join(new_ids)}")
if raised:  print(f"  overlay RAISES severity: {', '.join(sorted(raised))}")

if violations:
    print("")
    print("BLOCKED: overlay would WEAKEN the shared base detection floor:", file=sys.stderr)
    for v in violations:
        print(f"  - {v}", file=sys.stderr)
    print("An overlay may ADD rules or RAISE severity; it may NEVER weaken a base rule. "
          "(A base change goes through the base-owners path, not an overlay.)", file=sys.stderr)
    sys.exit(1)

print("")
print("OK: overlay only tightens (adds rules / raises severity); base floor preserved.")
sys.exit(0)
PYEOF

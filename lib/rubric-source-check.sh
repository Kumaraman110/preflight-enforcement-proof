#!/usr/bin/env bash
# rubric-source-check.sh — ENFORCE that every rubric rule carries structured PROVENANCE (a Source line).
#
# THE DEFECT THIS CLOSES (the correction earned in the §G2 review): rubric provenance relied on a
# `**Source:**` line that a human could simply OMIT — convention-trusted, not mechanism-guaranteed, which
# contradicts preflight's ethos (mechanism over convention). This check makes the Source line MECHANICAL:
# a rule with no valid structured Source line FAILS. Provenance becomes enforced, not hoped-for.
#
# WHAT A VALID SOURCE LINE IS (the structured, index-ready format — see lib/rubric-changelog-format.md):
#   **Source:** <origin> | <ref> | <date> | <op>
#     <origin>  the originating capture/finding (e.g. "calibration-log 2026-06-10", "copilot PR#95",
#               "base-author", "false-positive consume") — WHY the rule exists / where it came from.
#     <ref>     a PR / commit / issue reference (e.g. "PR#123", "commit a203bb7", "issue#10").
#     <date>    ISO-8601 date (YYYY-MM-DD).
#     <op>      one of: add | raise | loosen-base | tighten | base-author  (the change operation).
#   Example: **Source:** calibration-log 2026-06-10 | PR#123 | 2026-06-12 | add
#   (The legacy one-line prose form `**Source:** calibration-log entry from <date>, Survived: N, ...` from
#    docs/rubric-edit-process.md is ALSO accepted — see ACCEPT-LEGACY below — so existing rubrics are not
#    retroactively broken; new/edited rules should use the structured pipe form for index-readiness.)
#
# Usage:
#   bash lib/rubric-source-check.sh <rubric.md> [<rubric2.md> ...]
#     Checks that EVERY rule (### §<id>) in each file has a valid Source line within its block.
#   bash lib/rubric-source-check.sh --added <base-ref>   (CI/diff mode)
#     Checks only rules ADDED/CHANGED in the working tree vs <base-ref> for rubric files in the diff.
#     (Diff mode is best-effort and documented as such; the per-file mode is the robust one.)
#
# Exit (aligned toward parity-check's 0/1/2 convention for a later advisory→blocking promotion):
#   0 = all rules carry a valid Source line (CLEAN)
#   1 = ADVISORY violations — one or more rules missing/with-malformed Source (the ADVISORY-FIRST level)
#   2 = usage / parse error / no rubric found
#
# ADVISORY-FIRST (recommended initial enforcement level; owner can promote to blocking):
#   This check reports missing-Source as exit 1 (ADVISORY) by default — CI surfaces it without blocking,
#   exactly the WIRE-B advisory→corroborated→blocking pattern. To run it BLOCKING (a missing Source fails
#   the build / a PreToolUse gate exits 2), pass --blocking, which maps the advisory exit 1 to exit 2.
#   RECOMMENDATION: start ADVISORY (let provenance accumulate, surface gaps), promote to BLOCKING once the
#   existing rubrics are backfilled — promotion criterion documented in lib/rubric-changelog-format.md.

set -uo pipefail

BLOCKING=0
MODE="files"
ARGS=()
for a in "$@"; do
  case "$a" in
    --blocking) BLOCKING=1 ;;
    --added)    MODE="added" ;;
    *)          ARGS+=("$a") ;;
  esac
done

if [ "${#ARGS[@]}" -eq 0 ]; then
  echo "Usage: $0 <rubric.md> [...]   |   $0 --added <base-ref>   [--blocking]" >&2
  exit 2
fi

PYTHON_CMD=""
for c in python3 python; do
  if command -v "$c" &>/dev/null && "$c" -c "pass" &>/dev/null 2>&1; then PYTHON_CMD="$c"; break; fi
done
[ -n "$PYTHON_CMD" ] || { echo "ERROR: rubric-source-check needs a working python interpreter." >&2; exit 2; }

# Resolve the list of rubric files to check.
FILES=()
if [ "$MODE" = "added" ]; then
  BASE_REF="${ARGS[0]:-}"
  [ -n "$BASE_REF" ] || { echo "Usage: $0 --added <base-ref>" >&2; exit 2; }
  # Rubric files changed vs base-ref (best-effort: *.md under rubrics/ or examples/rubrics/ or named rubric-*).
  while IFS= read -r f; do
    [ -n "$f" ] && [ -f "$f" ] && FILES+=("$f")
  done < <(git diff --name-only "$BASE_REF"...HEAD 2>/dev/null | grep -E '(^|/)(rubric|.*rubric.*|overlay).*\.md$' || true)
  if [ "${#FILES[@]}" -eq 0 ]; then
    echo "rubric-source-check (--added): no changed rubric files vs $BASE_REF — nothing to check (CLEAN)."
    exit 0
  fi
else
  for f in "${ARGS[@]}"; do
    [ -f "$f" ] || { echo "ERROR: rubric not found: $f" >&2; exit 2; }
    FILES+=("$f")
  done
fi

# Per-file: parse rules and verify each carries a valid Source line in its block. Paths via ARGV (MSYS
# path translation; see the rubric-resolve note). Python prints violations and exits 1 if any, else 0.
"$PYTHON_CMD" - "${FILES[@]}" <<'PYEOF'
import re, sys, os

# Structured pipe form: **Source:** <origin> | <ref> | <YYYY-MM-DD> | <op>
OPS = r"(add|raise|loosen-base|tighten|base-author)"
STRUCTURED = re.compile(
    r'^\*\*Source:\*\*\s*.+\s*\|\s*.+\s*\|\s*\d{4}-\d{2}-\d{2}\s*\|\s*' + OPS + r'\s*$',
    re.IGNORECASE)
# ACCEPT-LEGACY: the existing prose form from docs/rubric-edit-process.md — a Source line that at least
# names an origin and a date-ish token. Accepted so existing rubrics aren't retroactively "broken"; the
# structured pipe form is required for NEW index-ready entries (CI advisory nudges toward it).
LEGACY = re.compile(r'^\*\*Source:\*\*\s*\S+.*\d{4}', re.IGNORECASE)

def check_file(path):
    """Return list of (rule_id, reason) violations: rules with no/invalid Source line in their block."""
    violations = []
    cur = None           # current rule id
    cur_has_source = False
    cur_source_kind = None
    def close(cur, has, kind):
        if cur is None:
            return
        if not has:
            violations.append((cur, "no **Source:** line in this rule's block"))
        elif kind == "malformed":
            violations.append((cur, "**Source:** present but malformed (need: <origin> | <ref> | <YYYY-MM-DD> | <op>, or the legacy 'from <date>' form)"))
    with open(path, "r", encoding="utf-8") as f:
        for raw in f:
            line = raw.rstrip("\n")
            m = re.match(r'^###\s+(§\S+)', line)
            if m:
                close(cur, cur_has_source, cur_source_kind)
                cur = m.group(1); cur_has_source = False; cur_source_kind = None
                continue
            if cur is None:
                continue
            if re.match(r'^\*\*Source:\*\*', line):
                cur_has_source = True
                if STRUCTURED.match(line) or LEGACY.match(line):
                    cur_source_kind = "ok"
                else:
                    cur_source_kind = "malformed"
        close(cur, cur_has_source, cur_source_kind)
    return violations

any_viol = False
total_rules = 0
for path in sys.argv[1:]:
    # count rules for the summary
    with open(path, "r", encoding="utf-8") as f:
        n = sum(1 for ln in f if re.match(r'^###\s+§', ln))
    total_rules += n
    viol = check_file(path)
    if viol:
        any_viol = True
        print(f"PROVENANCE GAP in {path}:", file=sys.stderr)
        for rid, reason in viol:
            print(f"  - {rid}: {reason}", file=sys.stderr)

if any_viol:
    print("", file=sys.stderr)
    print("Every rubric rule MUST carry a structured **Source:** line (provenance is a MECHANISM, not a", file=sys.stderr)
    print("convention): **Source:** <origin> | <ref> | <YYYY-MM-DD> | <op>. See lib/rubric-changelog-format.md.", file=sys.stderr)
    sys.exit(1)
print(f"rubric-source-check: CLEAN — all {total_rules} rule(s) carry a valid Source line.")
sys.exit(0)
PYEOF
RC=$?

if [ "$RC" -eq 1 ] && [ "$BLOCKING" -eq 1 ]; then
  echo "  (--blocking: provenance gap is BLOCKING — exit 2)" >&2
  exit 2
fi
exit $RC

#!/usr/bin/env bash
# TRUSTED reversibility-tier classifier (runs from the DEFAULT-branch checkout, NEVER from
# PR-controlled code). It derives the push-tier from the set of files the PR ACTUALLY changed
# between the base (default branch) and the subject head commit — a fact the PR author cannot
# forge. The producer/PR's own `.gate/artifacts/tier.txt` is an untrusted HINT, ignored here.
#
# ALLOWLIST model (fail-closed by default — hardened after an independent review found that a
# denylist default of AUTO auto-approved any unanticipated path, and that rename detection +
# core.quotePath let a protected change be reported as a safe path):
#   • start pessimistic;
#   • a changed path under a PROTECTED prefix (verifier/ protocol/ gate/ .github/ app/protected/)
#     → BLOCK (touching the judge/policy/gate/workflows/protected area is never auto-reversible);
#   • else a changed path under app/review/ → at least CONFIRM (needs a distinct approval);
#   • AUTO is granted ONLY when EVERY changed path matches an explicit SAFE allowlist
#     (app/safe/**, docs/**, or a small set of safe root docs);
#   • ANY path not on the safe allowlist and not review → BLOCK (unknown area is not auto-reversible);
#   • no resolvable diff → BLOCK.
#
# Robustness:
#   • --no-renames: a rename's SOURCE path is scored too, so renaming app/protected/x → app/safe/x
#     cannot launder a protected change into AUTO;
#   • -z + core.quotePath=false: NUL-delimited, unquoted paths, so a non-ASCII protected path cannot
#     evade the prefix match via octal-escaped quoting.
#
# Usage: classify-tier.sh <subject-dir> <base-sha> <head-sha>
# Prints exactly one of: AUTO | CONFIRM | BLOCK   (stdout, single line)
set -uo pipefail

SUBJ="${1:?subject dir}"; BASE="${2:?base sha}"; HEAD="${3:?head sha}"

MB="$(git -C "$SUBJ" merge-base "$BASE" "$HEAD" 2>/dev/null || echo "$BASE")"

# NUL-delimited, unquoted, rename-expanded diff. Read into an array so empty/odd paths are explicit.
mapfile -d '' -t CHANGED < <(git -C "$SUBJ" -c core.quotePath=false diff --no-renames -z --name-only "$MB" "$HEAD" 2>/dev/null)

# Drop empty entries.
FILES=()
for f in "${CHANGED[@]}"; do [ -n "$f" ] && FILES+=("$f"); done

if [ "${#FILES[@]}" -eq 0 ]; then
  echo "BLOCK"; exit 0            # no resolvable diff → fail closed
fi

# is_safe: the ONLY paths that may keep a change at AUTO.
is_safe() {
  case "$1" in
    app/safe/*|docs/*|README.md|LICENSE|.gitignore) return 0;;
    *) return 1;;
  esac
}

tier="AUTO"
for f in "${FILES[@]}"; do
  case "$f" in
    verifier/*|protocol/*|gate/*|.github/*|app/protected/*)
      echo "BLOCK"; exit 0;;                     # protected → decisive BLOCK
    app/review/*)
      tier="CONFIRM";;                           # needs approval (unless a later BLOCK)
    *)
      if ! is_safe "$f"; then
        # Unknown area — NOT on the safe allowlist and not review → not auto-reversible.
        echo "BLOCK"; exit 0
      fi;;
  esac
done

echo "$tier"

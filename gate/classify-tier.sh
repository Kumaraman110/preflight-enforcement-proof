#!/usr/bin/env bash
# TRUSTED reversibility-tier classifier (runs from the sandbox DEFAULT branch checkout,
# NEVER from PR-controlled code). It derives the push-tier from the set of files the PR
# ACTUALLY changed between the base (default branch) and the subject head commit — a fact
# the PR author cannot forge (git records what it changed). The producer/PR's own
# `.gate/artifacts/tier.txt` is an untrusted HINT and is deliberately ignored here.
#
# Rules (most-restrictive-wins), tuned so the adversarial matrix maps cleanly:
#   • any changed path under a PROTECTED prefix        → BLOCK
#     (verifier/ protocol/ gate/ .github/ app/protected/) — touching the judge, the policy,
#      the gate scripts, the workflows, or a protected app area is never auto-reversible.
#   • else any changed path under app/review/           → CONFIRM (needs a distinct approval)
#   • else (only app/safe/** or docs)                   → AUTO
#   • no changed files resolvable                        → BLOCK (fail-closed)
#
# Usage: classify-tier.sh <subject-dir> <base-sha> <head-sha>
# Prints exactly one of: AUTO | CONFIRM | BLOCK   (stdout, single line)
set -uo pipefail

SUBJ="${1:?subject dir}"; BASE="${2:?base sha}"; HEAD="${3:?head sha}"

# Compute changed files as (merge-base(base,head)..head). All git runs are against the
# fetched subject repo as DATA; no subject script is ever executed.
MB="$(git -C "$SUBJ" merge-base "$BASE" "$HEAD" 2>/dev/null || echo "$BASE")"
CHANGED="$(git -C "$SUBJ" diff --name-only "$MB" "$HEAD" 2>/dev/null)"

if [ -z "${CHANGED//[$'\t\r\n ']/}" ]; then
  # No resolvable diff → cannot establish reversibility → fail closed.
  echo "BLOCK"; exit 0
fi

tier="AUTO"
while IFS= read -r f; do
  [ -n "$f" ] || continue
  case "$f" in
    verifier/*|protocol/*|gate/*|.github/*|app/protected/*)
      echo "BLOCK"; exit 0;;              # protected → decisive BLOCK, short-circuit
    app/review/*)
      tier="CONFIRM";;                    # needs approval (unless a later line forces BLOCK)
  esac
done <<< "$CHANGED"

echo "$tier"

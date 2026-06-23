#!/usr/bin/env bash
# pre-branch-cut cleanliness check (G4) — warns/errors on uncommitted
# .claude/ or .preflight/ drift in the tree (the thing that forced
# stash-surgery during the SessionToken migration branch-cut).
#
# Usage:
#   bash lib/pre-branch-cut-check.sh [--fail] [--check-claude] [--check-preflight] [--check-blob-syntax]
#     --fail              exit 1 on any drift (default: warn only, exit 0)
#     --check-claude      also check for uncommitted .claude/ (default: on)
#     --check-preflight   also check for uncommitted .preflight/ (default: on)
#     --check-blob-syntax run `git show HEAD:<f> | bash -n` on every shipped
#                         executable; FAIL (exit 1, ignores --fail) on any syntax
#                         error in the COMMITTED blob (default: off — opt-in for cut)
#
# Exit: 0 = clean or warn-only · 1 = drift found with --fail, OR a committed-blob
#       syntax error with --check-blob-syntax · 2 = usage error
#
# This is a MECHANICAL check (git status + path matching + bash -n) — no LLM involved.
# The SessionToken run forced backup/stash/conflict-surgery because pre-existing
# uncommitted .claude/ + .preflight/ tooling drift existed in the working tree.
# This check prevents that class of friction.
#
# --check-blob-syntax exists because a mass/scripted edit once prefixed every line
# of 4 shipped hooks with an "N|" line-number marker (commit c0e01a4), breaking the
# shebang. The working tree may be fine while the COMMITTED blob — which the
# installer ships via `git show SHA:path` — is dead. A `bash -n` on the working
# tree would NOT catch it; this checks the blob the tag would actually ship.

set -uo pipefail

FAIL_MODE=false
CHECK_CLAUDE=true
CHECK_PREFLIGHT=true
CHECK_BLOB_SYNTAX=false

while [ $# -gt 0 ]; do
  case "$1" in
    --fail) FAIL_MODE=true ;;
    --check-claude) CHECK_CLAUDE=true ;;
    --no-check-claude) CHECK_CLAUDE=false ;;
    --check-preflight) CHECK_PREFLIGHT=true ;;
    --no-check-preflight) CHECK_PREFLIGHT=false ;;
    --check-blob-syntax) CHECK_BLOB_SYNTAX=true ;;
    *) echo "Usage: $0 [--fail] [--check-claude|--no-check-claude] [--check-preflight|--no-check-preflight] [--check-blob-syntax]" >&2; exit 2 ;;
  esac
  shift
done

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "ERROR: not in a git repository" >&2
  exit 2
fi

# ── Committed-blob syntax gate (catches the c0e01a4 dead-gate class) ──────────
# Runs FIRST and independently: a syntactically-dead shipped executable at HEAD is
# a hard cut-blocker regardless of working-tree cleanliness, so it exits 1 even
# without --fail (the dangerous direction must block).
if [ "$CHECK_BLOB_SYNTAX" = true ]; then
  BLOB_BAD=""
  while IFS= read -r f; do
    # Skip non-shell shipped files. .cmd is the Windows polyglot shim
    # (hooks/run-hook.cmd) which intentionally fails `bash -n` on its cmd half;
    # docs/specs/config are not executables.
    case "$f" in
      *.cmd|*.md|*.json|*.txt) continue ;;
    esac
    # Decide whether to syntax-check. Do NOT gate on a shebang match: the exact
    # corruption this guard exists for (c0e01a4's "N|" line prefix) mangles the
    # shebang into "1|#!/usr/bin/env bash", which a `^#!` test would MISS — a
    # false negative on the very case we hunt. Instead, check by location: every
    # extensionless file in hooks/ is a bash hook by repo convention, and every
    # lib/*.sh + tools/*.sh is a shell script. That set is exactly the shipped
    # executables; a broken shebang inside them still gets caught by bash -n.
    check=false
    base="${f##*/}"   # basename
    case "$f" in
      lib/*.sh|tools/*.sh) check=true ;;
      hooks/*) case "$base" in *.*) ;; *) check=true ;; esac ;;  # extensionless basename = a bash hook
    esac
    if [ "$check" = true ]; then
      # Capture the committed blob once and run THREE assertions. `bash -n` alone is
      # blind to a single-statement-per-line "N|" corruption: `1|#!/usr/bin/env bash\n
      # 2|echo hi\n3|exit 0` parses as valid grammar (command N piped into a comment)
      # → rc=0. Today's shipped files all have multi-line control flow (so the
      # c0e01a4 shape trips bash -n), but the gate must not rest on that unenforced
      # invariant. (M9) Add two STRUCTURAL checks independent of statement structure:
      #   (1) line-prefix scan — the c0e01a4 corruption prefixes EVERY line with "N|";
      #       flag if head-1 itself is "N|"-prefixed OR ≥2 CONSECUTIVE lines match
      #       ^[0-9]+\| (threshold avoids firing on one incidental table-row/heredoc line).
      #   (2) shebang sanity — head-1 of a shipped executable must start with "#!".
      # Any of the three failing → the blob is dead/corrupt → record it.
      BLOB="$(git show "HEAD:$f" 2>/dev/null)"
      bad_reason=""
      if ! printf '%s' "$BLOB" | bash -n 2>/dev/null; then
        bad_reason="bash -n syntax error"
      fi
      HEAD1="$(printf '%s\n' "$BLOB" | head -1)"
      # (1) line-prefix corruption: head-1 itself prefixed, or ≥2 consecutive N| lines.
      if printf '%s' "$HEAD1" | grep -qE '^[0-9]+\|'; then
        bad_reason="${bad_reason:+$bad_reason; }line-number 'N|' prefix on the shebang line (corrupted blob)"
      else
        MAXRUN="$(printf '%s\n' "$BLOB" | awk '/^[0-9]+\|/{c++; if(c>m)m=c; next}{c=0} END{print m+0}')"
        if [ "${MAXRUN:-0}" -ge 2 ]; then
          bad_reason="${bad_reason:+$bad_reason; }${MAXRUN} consecutive 'N|' line-number-prefixed lines (corrupted blob)"
        fi
      fi
      # (2) shebang sanity: a shipped executable's first line must be a shebang.
      case "$HEAD1" in
        '#!'*) ;;
        *) bad_reason="${bad_reason:+$bad_reason; }missing/mangled shebang (head-1 is not '#!...')" ;;
      esac
      if [ -n "$bad_reason" ]; then
        BLOB_BAD="${BLOB_BAD}  ${f} — ${bad_reason}\n"
      fi
    fi
  done < <(git ls-tree -r --name-only HEAD)
  if [ -n "$BLOB_BAD" ]; then
    echo "⛔ BLOB-SYNTAX GATE: shipped executable(s) FAIL bash -n on the COMMITTED HEAD blob:" >&2
    printf '%b' "$BLOB_BAD" >&2
    echo "These would ship dead via the installer (git show SHA:path). DO NOT TAG. Fix and re-commit." >&2
    exit 1
  fi
  echo "✓ BLOB-SYNTAX GATE: all shipped executables pass bash -n on the committed HEAD blob"
fi

DRIFT_FOUND=false
DRIFT_DETAILS=""

# Check .claude/ drift
if [ "$CHECK_CLAUDE" = true ]; then
  CLAUDE_DRIFT=$(git status --porcelain -- .claude/ 2>/dev/null | grep -v '^??' || true)
  if [ -n "$CLAUDE_DRIFT" ]; then
    DRIFT_FOUND=true
    DRIFT_DETAILS="${DRIFT_DETAILS}Uncommitted .claude/ changes:\n$CLAUDE_DRIFT\n\n"
  fi
  # Also check for untracked .claude/ files that aren't in .gitignore
  CLAUDE_UNTRACKED=$(git status --porcelain -- .claude/ 2>/dev/null | grep '^??' || true)
  if [ -n "$CLAUDE_UNTRACKED" ]; then
    DRIFT_FOUND=true
    DRIFT_DETAILS="${DRIFT_DETAILS}Untracked .claude/ files (not in .gitignore?):\n$CLAUDE_UNTRACKED\n\n"
  fi
fi

# Check .preflight/ drift
if [ "$CHECK_PREFLIGHT" = true ]; then
  PREFLIGHT_DRIFT=$(git status --porcelain -- .preflight/ 2>/dev/null | grep -v '^??' || true)
  if [ -n "$PREFLIGHT_DRIFT" ]; then
    DRIFT_FOUND=true
    DRIFT_DETAILS="${DRIFT_DETAILS}Uncommitted .preflight/ changes:\n$PREFLIGHT_DRIFT\n\n"
  fi
  # Untracked .preflight/ files that aren't runtime state (runtime state is gitignored)
  PREFLIGHT_UNTRACKED=$(git status --porcelain -- .preflight/ 2>/dev/null | grep '^??' | grep -vE '^\?\? \.preflight/(cache|derived|gate|metrics\.json|migrate-checkpoint\.json|config\.local\.json)' || true)
  if [ -n "$PREFLIGHT_UNTRACKED" ]; then
    DRIFT_FOUND=true
    DRIFT_DETAILS="${DRIFT_DETAILS}Untracked .preflight/ files (not runtime state, not in .gitignore?):\n$PREFLIGHT_UNTRACKED\n\n"
  fi
fi

if [ "$DRIFT_FOUND" = true ]; then
  echo "⚠ PRE-BRANCH-CUT CLEANLINESS CHECK: drift detected" >&2
  echo "" >&2
  printf '%b' "$DRIFT_DETAILS" >&2
  echo "Resolve by: commit the drift, stash it, or add to .gitignore (for untracked)." >&2
  if [ "$FAIL_MODE" = true ]; then
    echo "FAIL: --fail specified — exiting 1" >&2
    exit 1
  fi
else
  echo "✓ PRE-BRANCH-CUT CLEANLINESS CHECK: clean"
fi

exit 0

#!/usr/bin/env bash
# Behavioral guard for the A2 fix: no SOURCE surface may PRESCRIBE the broken Copilot
# reviewer-request mechanism `gh pr edit --add-reviewer` as the way to assign the bot.
#
# The bot login cannot be resolved by GraphQL `requestReviewsByLogin`, so `gh pr edit
# --add-reviewer copilot-pull-request-reviewer[bot]` silently fails (proven live, run 4/6).
# The working path is the `requested_reviewers` REST endpoint.
#
# This test distinguishes PRESCRIPTIVE from DESCRIPTIVE mentions (the critic's required
# revision — a bare-substring grep would falsely flag the legitimate cautionary text):
#   - PRESCRIPTIVE  = a line that presents `gh pr edit --add-reviewer` as the mechanism
#                     to use, with NO nearby caveat (fails / cannot resolve / NOT / cause).
#   - DESCRIPTIVE   = a line that mentions it WHILE flagging it as broken (these are
#                     allowed: they document why the REST path exists / post-mortems).
# A new prescriptive use (e.g. someone re-adding "run `gh pr edit --add-reviewer …`")
# has none of the caveat words on its line and is caught.
#
# Exit 0 = no prescriptive use remains; exit 1 = a prescriptive use was found.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "$ROOT"

# Lines mentioning the broken command across all shipped source surfaces.
MENTIONS="$(grep -rn --include='*.md' --include='*.sh' -- 'gh pr edit --add-reviewer' \
            agents skills lib hooks docs examples defaults 2>/dev/null || true)"

# A mention is ALLOWED only if its own line carries a caveat marking it as broken.
CAVEAT='fail|cannot resolve|cannot be resolved|does not resolve|swallow|NOT |not the|broken|error|CAUSE|proven in run'

PRESCRIPTIVE="$(printf '%s\n' "$MENTIONS" | grep -v '^$' | grep -viE "$CAVEAT" || true)"

echo "All 'gh pr edit --add-reviewer' mentions in source:"
printf '%s\n' "${MENTIONS:-  (none)}" | sed 's/^/  /'
echo ""

if [ -z "$PRESCRIPTIVE" ]; then
  echo "PASS: no PRESCRIPTIVE 'gh pr edit --add-reviewer' use remains (all mentions are caveated/descriptive)"
  echo ""
  echo "copilot-reviewer-path: 1 passed, 0 failed"
  exit 0
else
  echo "FAIL: prescriptive use(s) of the broken reviewer-request command found:" >&2
  printf '%s\n' "$PRESCRIPTIVE" | sed 's/^/  /' >&2
  echo ""
  echo "copilot-reviewer-path: 0 passed, 1 failed"
  exit 1
fi

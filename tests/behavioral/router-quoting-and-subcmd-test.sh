#!/usr/bin/env bash
# router-quoting-and-subcmd-test.sh — two adversarial-review findings on git-push classification:
#
#   A. ROUTER QUOTING BYPASS (HIGH silent-allow): the pre-bash-risk-router candidate recognizer word-split
#      tokens but did NOT unquote them, so `"git" push`, `git "push"`, `git 'push'`, `git p"ush"`, `git""
#      push`, `"gh" pr merge`, `gh pr "merge"` (all valid commands — bash strips the quotes at runtime and
#      runs a real governed op) FAILED the literal `case`/`[ = ]` matches → NOT flagged as candidates → the
#      engine never ran → silent allow. The recognizer must unquote tokens so these route to the engine.
#      Non-candidates (echo/git status/grep -C/echo git push) must stay fast-allow (no over-block).
#
#   B. GIT 2-TOKEN SUBCMD FALSE-POSITIVE (MEDIUM false-block): the IR lexer read a 2-token subcommand
#      window for git too, so `git stash push` / `git config push` / `git tag push` matched the engine's
#      `*" push "*` and were mis-flagged as pushes. For GIT the subcommand is the single first non-option
#      token; the 2-token window is only for gh's two-word verbs (`gh pr create/merge`).
#
# Layer A is tested at the ROUTER (a fake fast engine signals "routed" via exit 2; no real engine spawn).
# Layer B is tested at the IR LEXER (deterministic, via shell-structure.sh). Neither spawns the heavy engine.
#
# Exit 0 = all passed.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
PASS=0; FAIL=0
ok(){ echo "PASS: $1"; PASS=$((PASS+1)); }
bad(){ echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }

# ── Layer A: router candidate recognizer (fake engine = exit 2 when routed) ────────────────────────────
D="$(mktemp -d)/rt"; mkdir -p "$D"
cp "$REPO/hooks/pre-bash-risk-router" "$D/"
printf '#!/usr/bin/env bash\ncat >/dev/null\nexit 2\n' > "$D/pre-push-gate-engine"; chmod +x "$D/pre-push-gate-engine"
GOV="$(mktemp -d)/gov"; mkdir -p "$GOV/.preflight"; echo '{"mode":"generic"}' > "$GOV/.preflight/config.json"
routed(){ printf '{"tool_name":"Bash","tool_input":{"command":"%s"},"cwd":"%s"}' "$1" "$GOV" | bash "$D/pre-bash-risk-router" >/dev/null 2>&1; echo $?; }
# rc 2 = routed to engine (candidate detected); rc 0 = fast-allow (non-candidate)

# A1-A7: quoted-token governed forms MUST route (rc 2). Previously silent-allowed (rc 0).
for c in '"git" push origin main' \
         'git "push" origin main' \
         "git 'push' origin main" \
         'git p"ush" origin main' \
         'git"" push origin main' \
         '"gh" pr merge 5' \
         'gh pr "merge" 5'; do
  rc="$(routed "$c")"
  [ "$rc" = 2 ] && ok "A quoted governed form routes to engine: $c" || bad "A quoted governed form NOT routed (silent-allow): $c (rc=$rc)"
done

# A8: plain unquoted push still routes (control)
[ "$(routed 'git push origin main')" = 2 ] && ok "A plain git push routes (control)" || bad "A plain git push not routed"

# A9-A12: true non-candidates MUST stay fast-allow (rc 0) — no over-route from the unquote/wrapper changes.
# NOTE: these contain NO bare `git`/`gh` program WORD (grep's arg is `push`, not `git`), so the wrapper
# structural catch-all does not route them. `echo git push` is handled separately below — it DOES contain a
# bare `git` word, so the catch-all now (by design) routes it to the engine, which classifies `echo` as
# DATA-ONLY and ALLOWs it. That over-route is SAFE (latency only); the router is a pre-filter, the engine is
# authoritative. Asserting the router fast-exits `echo git push` would encode the OLD (fail-open-adjacent)
# behavior where a bare governed word behind an unknown program was NOT inspected.
for c in 'echo hello' 'git status' 'ls -la' 'grep -C 3 push file'; do
  rc="$(routed "$c")"
  [ "$rc" = 0 ] && ok "A non-candidate stays fast-allow: $c" || bad "A over-routed a true non-candidate: $c (rc=$rc)"
done
# A13: `echo git push` contains a bare `git push` — the wrapper structural catch-all ROUTES it to the engine
# (rc 2 against the stub engine), which is correct: the engine's DATA-ONLY taxonomy then ALLOWs it. We assert
# it ROUTES (the safe direction) rather than silently fast-exits, matching the closed-wrapper-fail-open design.
[ "$(routed 'echo git push')" = 2 ] && ok "A 'echo git push' (bare governed word) routes to the engine (DATA-ONLY→allow there)" || bad "A 'echo git push' not routed — a bare governed word behind an unknown program must reach the engine"

# ── Layer B: IR lexer git subcommand (single-token for git; 2-token only for gh) ───────────────────────
. "$REPO/lib/shell-structure.sh"
sub_of(){ pfg_ss_parse "$1" >/dev/null 2>&1; printf '%s' "${PFG_SS_SUBCMD[0]:-}"; }
is_push(){ case " $(sub_of "$1") " in *" push "*) echo yes;; *) echo no;; esac; }

# B1: git push IS a push
[ "$(is_push 'git push origin main')" = yes ] && ok "B git push → push (detected)" || bad "B git push not detected"
# B2: git -C <dir> push IS a push (alt-context preserved)
[ "$(is_push 'git -C /x push origin main')" = yes ] && ok "B git -C <dir> push → push (detected)" || bad "B git -C push not detected"
# B3-B5: git stash/config/tag push are NOT pushes (false-positive gone)
for c in 'git stash push' 'git config push' 'git tag push'; do
  [ "$(is_push "$c")" = no ] && ok "B non-push git subcommand not flagged: $c" || bad "B false-positive push: $c (subcmd=$(sub_of "$c"))"
done
# B6: git stash push -m wip still not a push
[ "$(is_push 'git stash push -m wip')" = no ] && ok "B git stash push -m wip → not a push" || bad "B git stash push -m wip false-flagged"
# B7-B8: gh two-word verbs still captured (2-token window preserved for gh)
[ "$(sub_of 'gh pr create')" = "pr create" ] && ok "B gh pr create → 'pr create' (2-token preserved)" || bad "B gh pr create subcmd wrong: $(sub_of 'gh pr create')"
[ "$(sub_of 'gh pr merge 5')" = "pr merge" ] && ok "B gh pr merge → 'pr merge' (2-token preserved)" || bad "B gh pr merge subcmd wrong: $(sub_of 'gh pr merge 5')"

echo ""
echo "router-quoting-and-subcmd: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

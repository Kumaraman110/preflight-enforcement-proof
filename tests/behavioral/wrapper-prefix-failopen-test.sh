#!/usr/bin/env bash
# wrapper-prefix-failopen-test.sh — closes the command-wrapper fail-open (adversarial-review P0).
#
# THE DEFECT: the router's builtins-only candidate recognizer, the engine's fast-parse, and the IR lexer
# each peeled only VAR=/command prefixes — NOT the command WRAPPERS env/exec/builtin/nohup/nice/time/setsid/
# stdbuf/timeout. So a governed `git push` / `gh pr create|merge` prefixed with any of those (an extremely
# common, non-adversarial spelling — `env GIT_SSH_COMMAND=… git push`, `nohup git push`, `timeout 30 git
# push`) was classified NON-candidate: the router exited 0, the engine was NEVER invoked, and the push
# reached the tool COMPLETELY UNGATED (fail-open). This test proves all three layers now peel the wrapper set.
#
# Exit 0 = all pass.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
ROUTER="$ROOT/hooks/pre-bash-risk-router"
LIB="$ROOT/lib/shell-structure.sh"
PASS=0; FAIL=0
ok(){ echo "PASS: $1"; PASS=$((PASS+1)); }
bad(){ echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }
[ -f "$ROUTER" ] && [ -f "$LIB" ] || { bad "router or lib missing"; echo "wrapper-prefix-failopen: 0/1"; exit 1; }

# ── Layer 1: the ROUTER must route a wrapper-prefixed governed candidate to the engine (exit 2 via a stub
#    that marks invocation), and must NOT route ordinary wrapper-prefixed commands. ──
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
cp "$ROUTER" "$T/pre-bash-risk-router"
cat > "$T/pre-push-gate-engine" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null; echo "ENGINE-INVOKED" >&2; exit 2
EOF
chmod +x "$T/pre-push-gate-engine"
route_invoked(){ printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$1" | bash "$T/pre-bash-risk-router" 2>"$T/e"; local rc=$?; grep -q ENGINE-INVOKED "$T/e" && echo "yes:$rc" || echo "no:$rc"; }

# governed pushes/PRs behind every wrapper → engine MUST be invoked
for c in \
  "git push origin main" \
  "env git push origin main" \
  "exec git push origin main" \
  "builtin git push origin main" \
  "env GIT_TERMINAL_PROMPT=0 git push origin main" \
  "env -i git push origin main" \
  "env -u FOO git push origin main" \
  "nohup git push origin main" \
  "nice git push origin main" \
  "nice -n 10 git push origin main" \
  "time git push origin main" \
  "setsid git push origin main" \
  "stdbuf -oL git push origin main" \
  "timeout 30 git push origin main" \
  "env exec git push origin main" \
  "env gh pr create --title x" \
  "exec gh pr merge 12" \
  ; do
  r="$(route_invoked "$c")"
  case "$r" in yes:*) ok "router routes governed candidate: '$c'";; *) bad "router did NOT route governed candidate (FAIL-OPEN): '$c' → $r";; esac
done

# ordinary wrapper-prefixed commands → engine must NOT be invoked (no over-routing of normal work)
for c in \
  "ls -la" \
  "env FOO=bar ls" \
  "env git status" \
  "nice -n 5 make build" \
  "nohup npm run dev" \
  "timeout 30 sleep 5" \
  "echo push to origin" \
  ; do
  r="$(route_invoked "$c")"
  case "$r" in no:0) ok "router fast-allows ordinary wrapped cmd: '$c'";; *) bad "router over-routed an ordinary cmd: '$c' → $r";; esac
done

# ── Layer 2: the IR parser (authoritative) must IDENTIFY the git-push subcommand under each wrapper (so the
#    engine's heavy path gates it even when fast-parse bails). SUBCMD=push proves identification. ──
ir_subcmd(){ LC_ALL=C bash -c 'source "$1" 2>/dev/null; pfg_ss_parse "$2" >/dev/null 2>&1; printf "%s" "${PFG_SS_SUBCMD_JOINED[0]:-$PFG_SS_SUBCMD}"' _ "$LIB" "$1" 2>/dev/null; }
for c in \
  "env git push origin main" \
  "nohup git push origin main" \
  "nice -n 10 git push origin main" \
  "timeout 30 git push origin main" \
  "stdbuf -oL git push origin main" \
  "setsid git push origin main" \
  ; do
  s="$(ir_subcmd "$c")"
  case "$s" in push*) ok "IR identifies push under wrapper: '$c' → subcmd='$s'";; *) bad "IR did NOT identify push under wrapper: '$c' → subcmd='$s'";; esac
done
# gh pr create/merge subcommand under a wrapper
for c in "env gh pr create" "nohup gh pr merge 12"; do
  s="$(ir_subcmd "$c")"
  case "$s" in "pr create"|"pr merge") ok "IR identifies gh-pr under wrapper: '$c' → '$s'";; *) bad "IR missed gh-pr under wrapper: '$c' → '$s'";; esac
done

echo ""
echo "wrapper-prefix-failopen: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

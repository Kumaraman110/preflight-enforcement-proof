#!/usr/bin/env bash
# wrapper-taxonomy-test.sh — the engine-side command-wrapper TAXONOMY (adversarial-review P0 completion).
#
# The router routes any segment with a bare git/gh word behind an unrecognized program to the engine
# (over-routing is safe). The engine must then NEVER silently ALLOW a governed push behind a wrapper. The
# taxonomy (user-decided) classifies the leading program:
#   • TRANSPARENT (env/env -S/sudo/doas/nice/ionice/chrt/taskset/flock/command/builtin/nohup/setsid/timeout/
#     exec/stdbuf/…) — exec the wrapped command locally → PEEL + apply NORMAL push policy (so a forbidden
#     destination BLOCKs exactly as the bare command would).
#   • REMOTE/ISOLATED (ssh/docker/podman/kubectl/nsenter/chroot) with a governed token → CONFIRM (ask).
#   • DATA-ONLY (echo/printf/grep/…) with a literal git/gh arg → ALLOW (no gate).
#   • UNKNOWN leading program + governed token → CONFIRM (ask) interactively; BLOCK when PREFLIGHT_HEADLESS=1.
#
# Drives the REAL engine against isolated temp repos (a FORBIDDEN-remote consumer so a gated push → exit 2,
# an ungated push → exit 0). Exit 0 = all pass. No network.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
ENGINE="$ROOT/hooks/pre-push-gate-engine"
PASS=0; FAIL=0
ok(){ echo "PASS: $1"; PASS=$((PASS+1)); }
bad(){ echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }
[ -f "$ENGINE" ] || { bad "engine missing"; echo "wrapper-taxonomy: 0/1"; exit 1; }
command -v git >/dev/null 2>&1 || { echo "SKIP: no git"; echo "wrapper-taxonomy: 0 passed, 0 failed"; exit 0; }
command -v jq  >/dev/null 2>&1 || { echo "SKIP: no jq"; echo "wrapper-taxonomy: 0 passed, 0 failed"; exit 0; }

# FORBIDDEN-remote consumer repo: a gated push to origin → BLOCK (exit 2); an ungated/allowed → exit 0.
R="$(mktemp -d)/r"; mkdir -p "$R/.preflight"; ( cd "$R" && git init -q && git remote add origin https://github.com/x/y.git ) 2>/dev/null
printf '%s\n' '{"mode":"generic","branch":{"base":"main","remote":"origin","forbiddenRemotes":["origin"]}}' > "$R/.preflight/config.json"
trap 'rm -rf "$(dirname "$R")" 2>/dev/null || true' EXIT

# run the engine on a command; echo "<rc> <decision-or-firststderr>"
run(){ local cmd="$1" hdl="${2:-0}"
  local out rc json
  # jq-build the stdin JSON: the `cwd` field carries $R (a mktemp path), which on a windows-latest CI
  # checkout is a BACKSLASH path (D:\a\...) — raw %s interpolation made the JSON invalid there → the engine
  # could not locate the repo config → forbiddenRemotes not detected → a spurious "allow" (test FAIL, not a
  # product defect). --arg escapes any path shape. (The command values here are path-free; the cwd was the bug.)
  json="$(jq -n --arg c "$cmd" --arg w "$R" '{tool_name:"Bash",tool_input:{command:$c},cwd:$w}')"
  out="$(printf '%s' "$json" \
        | ( cd "$R" && PF_USER_LEVEL=1 PF_REPO_ROOT="$R" PFG_SS_IR_TIMEOUT="${PFG_SS_IR_TIMEOUT:-90}" PREFLIGHT_HEADLESS="$hdl" bash "$ENGINE" 2>/tmp/.wtax.$$ ))"
  rc=$?
  local dec; dec="$(printf '%s' "$out" | grep -o '"permissionDecision":"[a-z]*"' | head -1)"
  if [ -n "$dec" ]; then echo "ask"; elif [ "$rc" -eq 2 ]; then echo "block"; elif [ "$rc" -eq 0 ]; then echo "allow"; else echo "err$rc"; fi
  rm -f "/tmp/.wtax.$$" 2>/dev/null || true
}

# ── TRANSPARENT wrappers over a FORBIDDEN push → must BLOCK (peel + normal policy) ────────────────────────
for c in \
  "git push origin main" \
  "env git push origin main" \
  "env GIT_SSH_COMMAND=ssh git push origin main" \
  "env -S 'git push origin main'" \
  "sudo git push origin main" \
  "sudo -u ci git push origin main" \
  "doas git push origin main" \
  "nice git push origin main" \
  "nice -n 10 git push origin main" \
  "ionice git push origin main" \
  "ionice -c2 -n0 git push origin main" \
  "chrt -f 10 git push origin main" \
  "taskset -c 0 git push origin main" \
  "flock /tmp/l git push origin main" \
  "nohup git push origin main" \
  "setsid git push origin main" \
  "stdbuf -oL git push origin main" \
  "timeout 30 git push origin main" \
  "exec git push origin main" \
  "env exec nice git push origin main" \
  ; do
  r="$(run "$c")"
  [ "$r" = "block" ] && ok "TRANSPARENT gated: '$c' → BLOCK" || bad "TRANSPARENT NOT gated: '$c' → $r (must BLOCK a forbidden push)"
done

# ── REMOTE/ISOLATED executors with a governed token → CONFIRM (ask), NOT local-git policy ─────────────────
for c in \
  "ssh host git push origin main" \
  "docker run img git push origin main" \
  "podman exec c git push origin main" \
  "kubectl exec pod -- git push origin main" \
  ; do
  r="$(run "$c")"
  [ "$r" = "ask" ] && ok "REMOTE confirm: '$c' → ask" || bad "REMOTE not confirmed: '$c' → $r (must ask)"
done

# ── DATA-ONLY commands with a literal git/gh arg → ALLOW (not an execution) ───────────────────────────────
for c in \
  "echo git push origin main" \
  "grep gh file.txt" \
  "printf 'git push'" \
  ; do
  r="$(run "$c")"
  [ "$r" = "allow" ] && ok "DATA-ONLY allowed: '$c' → allow" || bad "DATA-ONLY not allowed: '$c' → $r (must allow)"
done

# ── UNKNOWN leading program + governed token → CONFIRM interactively, BLOCK headless (never silent ALLOW) ──
r="$(run "myscript git push origin main" 0)"
[ "$r" = "ask" ]   && ok "UNKNOWN interactive: 'myscript git push' → ask"   || bad "UNKNOWN interactive: got $r (must ask)"
r="$(run "myscript git push origin main" 1)"
[ "$r" = "block" ] && ok "UNKNOWN headless: 'myscript git push' → BLOCK"    || bad "UNKNOWN headless: got $r (must block)"
r="$(run "./deploy.sh gh pr merge 5" 1)"
[ "$r" = "block" ] && ok "UNKNOWN headless (gh): './deploy.sh gh pr merge' → BLOCK" || bad "UNKNOWN headless gh: got $r (must block)"

# ── ORDINARY commands (no governed token) → ALLOW, never gated ────────────────────────────────────────────
for c in \
  "ls -la" \
  "make build" \
  "npm run dev" \
  "nice -n 5 make build" \
  "env FOO=bar ls" \
  "sudo systemctl restart nginx" \
  ; do
  r="$(run "$c")"
  [ "$r" = "allow" ] && ok "ORDINARY allowed: '$c' → allow" || bad "ORDINARY over-gated: '$c' → $r (must allow)"
done

echo ""
echo "wrapper-taxonomy: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

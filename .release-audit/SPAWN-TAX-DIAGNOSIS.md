# Subprocess-spawn-tax diagnosis — push-gate / spec-divergence on Windows/Git-Bash

**Verdict:** the tax is an **environmental per-process-creation cost (~700–1000 ms/spawn)** on this
corporate Windows/Git-Bash box — almost certainly an **endpoint security agent scanning every process
creation** (Defender real-time / Zscaler-class). It is **NOT git-specific, NOT credential-helper-specific,
NOT network-related, and NOT code-fixable** by the hook. Code can only reduce the *number* of spawns, which
is **outcome-neutral** here (it doesn't get the gate under 10 s on this box, and production already passes
with margin). **Task 1 is therefore diagnosis + an environment recommendation; no hook code was changed**
(changing the security-critical, freshly-wedge-hardened gate to shave a few spawns is not a clean,
low-risk, isolated win — see "Fix direction").

This is the load-bearing finding for tomorrow's scaffold run: see "Impact" — the run is **fine on a normal
host; on THIS box the push-gate will not complete in budget (fails CLOSED, not open) and the engine will be
slow-but-functional, not broken.**

---

## 1. The tax, measured (this session, this box)

External **process creation** costs ~700–1000 ms each. Shell builtins are ~33 ms. The cost is on *exec*,
not on what is exec'd:

| What | per-call | notes |
|---|---|---|
| shell builtin loop (no exec) | ~33 ms | `for i in …; do :; done` |
| `true` (builtin) | ~32 ms | bash builtin, no spawn |
| `/bin/true` (external) | ~720 ms | forced external exec of a trivial binary |
| `bash -c true` (fork+exec) | ~800 ms | full subshell |
| `/usr/bin/env true` | ~870 ms | external exec via env |
| `cat /dev/null` (38 KB binary) | ~720–950 ms | tiny non-git/non-jq binary |
| `git --version` (no repo/net/cred) | ~1000 ms | git, but nothing that touches network/credential |
| `git rev-parse HEAD` (local) | ~1100 ms | local repo read |
| `git remote get-url origin` (local) | ~1280 ms | local config read — **same order as `git --version`** |
| `jq --version` | ~1450 ms | jq |

**Constant, not first-spawn-only:** re-running `cat /dev/null ×10` immediately stays ~7–9 s total → the
cost is paid on **every** spawn (scan-on-exec), not a one-time cold cache. High `sys` time (3–6 s across the
loops) is the signature of **kernel-mediated process-creation interception**, i.e. an endpoint agent.

## 2. Suspect, narrowed with evidence

- **(a) Endpoint AV / process-creation scanning — CONFIRMED most likely.** Even `cat /dev/null` (38 KB,
  no network, no git) costs ~720 ms, and the cost is per-spawn with high `sys` time. That is the classic
  scan-every-CreateProcess signature. **This is the dominant cause.**
- **(b) Zscaler / network interception — RULED OUT as the primary.** `git --version` (zero network) is as
  slow as `git remote get-url` (local config read). The hook's git ops never reach the network, yet pay
  full freight → the tax is at exec, not at any socket.
- **(c) Git Credential Manager — RULED OUT as the primary.** `credential.helper = manager` *is*
  configured, but `git --version` never invokes it and is still ~1 s. The helper would only add cost on
  actual remote ops (push/fetch) — the hook's reads (`rev-parse`, `remote get-url`) don't trigger it.
  (It *may* add latency to the real `git push` the agent runs afterwards — separate from the hook.)
- **(d) Git-Bash fork emulation on Windows — a CONTRIBUTOR, not the whole story.** MSYS fork/exec on
  Windows is inherently costly, but a bare-name-vs-absolute-path test showed no PATH-resolution premium;
  the dominant `sys` cost points past pure fork emulation to a scanning hook on CreateProcess.
- **(e) Long PATH (46 entries) — negligible.** `/bin/true` with an absolute path was still ~720 ms.

**Conclusion:** an endpoint security agent scanning each process image at creation. **Environmental. Owner
must address it at the endpoint layer (an exclusion), not in framework code.**

## 3. Impact on tomorrow's scaffold run (with the measured numbers)

**Push-gate hook — actual spawns on the normal AUTO push path: 27** (measured by shadowing git/jq/grep/sed
with logging wrappers: 12 grep, 9 git, 5 jq, 1 sed).

- **Normal/production host (~5 ms/spawn):** 27 × 5 ms ≈ **135 ms** → completes comfortably under the 8 s
  watchdog and the 10 s platform kill. ✅ **The gate works in production.**
- **THIS box (~700 ms/spawn):** 27 × 700 ms ≈ **19 s** (measured end-to-end body: 37–58 s under load) →
  **exceeds the 10 s platform kill.** ✗ But because of the v0.9.1 wedge fix, this fails **CLOSED**
  (exit 2 = push blocked), **not open** — so a push on this box is *blocked/retried*, never silently
  let through. The owner can push from a human shell (the eyes-on path) when the gate can't complete.

**Spec-divergence engine — NOT broken, just slow on this box.** The engine fires 7 agents (4 interpreters
+ 3 judges). Each agent is an LLM call (seconds of model latency) that *internally* spawns some
subprocesses. The ~700 ms/spawn tax adds per-agent overhead but does **not** change correctness — the
engine will *function* live, it will just be slower. **Critical caveat for tomorrow:** if the engine
"appears not to fire" on this box, suspect the spawn tax / agent-dispatch latency **first**, before
concluding the engine is broken. A slow live run here is the environment, not a logic failure. (The engine
mechanical core + wiring are test-proven: engine 11/0, wiring 10/0, POCs 8/0 + 8/0.)

## 4. Fix direction (recommendation; NO hook code changed)

- **The tax itself is not code-fixable.** It is endpoint process-creation scanning. The genuine fix is an
  **environment action by the owner:** add a Microsoft Defender (or the deployed endpoint agent) **exclusion**
  for the Git-Bash toolchain and the working tree, e.g. exclude `C:\Program Files\Git\` (git/bash/usr
  binaries), the user's `~/bin` (jq), and the repo path `C:\Users\v173617\Source_Code\code-forge\`. This is
  the single highest-leverage action and it is **outside framework code.** (Confirm with the endpoint/IT
  team; corporate policy may forbid self-service exclusions.)
- **Spawn reduction in the hook — considered and DECLINED as outcome-neutral + risky.** There is one real
  redundancy: `git remote get-url "$ARG_REMOTE"` is called twice on a named-remote push
  (`hooks/pre-push-gate-check:529` in the B0 forbidden check and `:609` in the GAP-A check). Caching it
  would save **1 spawn out of 27 (~4 %)** — which changes the outcome on **neither** host (production
  already passes; this box still needs ~25 × 700 ms ≈ 17.5 s > 10 s). Shaving it requires threading a
  cache variable through ~80 lines of the **security-critical classification logic I just wedge-hardened**,
  for a measurable-but-irrelevant gain. Per the build contract ("don't force a risky change"; "no
  clean+isolated fix → diagnose + recommend only"), **I did not make it.** The sentinel-mint tripwire — the
  other big spawn consumer — is **already** spawn-conscious: its 7 expensive sub-greps are gated behind a
  single cheap `grep` guard (`:214`, `:238`), so a normal push that contains no `.preflight/gate/` path
  pays only 2 greps there, not 9.
- **The timeout knobs (for the owner, on a slow host) — do NOT ship a blanket raise.** The 10 s budget is
  `pre-push-gate-check`'s OWN registration in `hooks/hooks.json` (`"timeout": 10000`), not an immutable
  platform floor (Claude Code's default command-hook timeout is 600 s). BUT raising it alone does **not**
  help: the wedge watchdog's internal deadline (default 8 s, env `PREFLIGHT_PUSH_GATE_DEADLINE`, clamped
  `[2,9]` so it can never exceed the 10 s kill) would still SIGKILL a legitimate 19 s body. Making the gate
  *usable* on this box would require raising **both** the watchdog clamp ceiling **and** the hooks.json
  timeout in concert — a coupled multi-file change that **weakens the wedge fail-closed guarantee for every
  consumer** to accommodate one pathological box. That trade is the owner's to make deliberately, per host
  — not a default to bake in. **Recommended owner action order:** (1) endpoint exclusion (fixes the root
  cause for everything, no framework change); (2) only if (1) is impossible, raise *this box's*
  `PREFLIGHT_PUSH_GATE_DEADLINE` toward its clamp and bump the local hooks.json timeout, accepting the
  reduced wedge margin **on that box only**.

---

## What I did NOT verify (honest list)

- **The exact endpoint agent.** I did not read Defender/Zscaler config or process-monitor traces (no
  admin access assumed; read-only investigation). The "endpoint scan-on-exec" conclusion is inferred from
  the spawn-cost *signature* (constant per-spawn, high sys time, non-git/non-network), not from a config
  dump. A definitive confirmation would be Process Monitor showing the AV filter-driver on CreateProcess,
  or measuring spawn cost with real-time protection temporarily disabled (owner/IT action).
- **Production-host spawn cost.** The ~5 ms/spawn production figure is a standard-Linux/Mac estimate, not
  measured on the owner's actual production host. The conclusion "completes under 10 s in production" holds
  for any host without scan-on-exec (orders of magnitude of margin: 27 spawns), but I did not run it on
  the real target.
- **The live scaffold run.** I did not run the engine live (out of scope — owner does that tomorrow). The
  "slow but functional" claim for the engine is an inference from the per-spawn tax + the test-proven core,
  not an observed live fire.
- **The credential-helper cost on the real `git push`.** I ruled it out for the *hook's read ops*, but did
  not measure whether `credential.helper = manager` adds latency to the actual push the agent runs after
  the gate clears (that push is outside the hook and outside this task's scope).
- **Whether an endpoint exclusion is permitted** by corporate policy — that's an owner/IT determination.

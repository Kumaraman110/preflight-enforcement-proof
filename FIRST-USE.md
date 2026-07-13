# Preflight — First Use

Preflight is a local, opt-in guard for consequential Git operations (pushes, PR
merges). It sits in front of your shell's `git push` and classifies each push by
how reversible it is:

- **ALLOW** — ordinary commands and reversible pushes proceed automatically.
- **CONFIRM** — a consequential push (protected branch, unexpected remote) asks
  for one confirmation instead of running silently.
- **BLOCK** — a never-OK operation (force-push to a shared branch, a denylisted
  remote) is refused.

It is **advisory / agent-side** (a guard on the Bash tool), not server-side
branch protection. It never changes tracked files in your repo.

---

## Install once (per user)

```sh
preflight install --user --ref v0.10.0
```

This installs an immutable runtime under `~/.claude/preflight/` and puts the
`preflight` command on your PATH (`~/bin` or `~/.local/bin`). Nothing else on
your machine changes; your `~/.claude/settings.json` gets exactly one hook entry
(all your other settings are preserved).

Check it:

```sh
preflight version      # the active runtime version
preflight doctor       # dependencies, runtime health, and any problems + fixes
```

---

## Turn it on for a repository

From inside the repo you want to guard:

```sh
cd /path/to/your/repo
preflight init --local
```

`init --local` writes a Preflight-owned `.preflight/config.json` and adds
`/.preflight/` to `.git/info/exclude`. **No tracked file changes** — the config
is local and gitignored.

Confirm it is active:

```sh
preflight status
```

You'll see `active here: YES`, the owner (USER), the version, the policy tier,
runtime health, and whether remote enforcement is configured.

> Before your first push, open `.preflight/config.json` and verify
> `branch.remote` points at your intended push target (not a production repo).
> Add prod remotes to `branch.forbiddenRemotes` to hard-block them.

---

## What you'll see day to day

| You run | Preflight |
|---|---|
| `git status`, `ls`, `git log`, ordinary work | **allows** instantly |
| `git push <expected-remote> <topic-branch>` | allows (reversible) |
| `git push origin main` (protected branch) | **asks** you to confirm |
| `git push <unexpected-remote>` | **asks** you to confirm |
| `git push --force origin main` (shared branch) | **blocks** |
| a push to a `forbiddenRemotes` entry | **blocks** |

Ordinary commands are never gated.

---

## Diagnose and manage

```sh
preflight status        # is it active here? who owns it? version, health, policy
preflight doctor        # diagnose duplicate hooks, stale runtime, bad config, missing deps — with fixes
preflight verify        # integrity of the installed runtime
```

---

## Turn it off

```sh
preflight disable            # deactivate THIS repo (reversible; keeps your config)
preflight init --local       # re-enable THIS repo
preflight uninstall --user   # remove Preflight entirely (your other settings are preserved)
```

`disable` just renames the local config to `config.json.disabled`, so the guard
stops running for that repo; `init --local` restores it. Neither touches any
tracked file.

---

## Notes

- **Performance:** ordinary commands and the inactive path add no measurable
  friction. A consequential push (the CONFIRM/BLOCK decision) is bounded and, if
  the decision engine can't finish in time, it **fails closed** (blocks) rather
  than letting an unverified push through. On hosts with aggressive
  scan-on-exec endpoint security, a push decision may take a few seconds.
- **Scope:** Preflight guards the agent's Bash tool. It is not a replacement for
  server-side branch protection — see `docs/parity-gate-limitations.md`.

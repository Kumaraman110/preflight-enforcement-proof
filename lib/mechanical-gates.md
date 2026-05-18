# Mechanical Gate Enforcement

## Why Prompts Are Not Enough

Every `<HARD-GATE>` in code-forge is a markdown instruction that the LLM reads and (usually) follows. But:

- At 65%+ context, attention drifts from instructions read 40K tokens ago
- Under user pressure ("just push it"), the model weighs user instruction against HARD-GATE
- When logical contradictions arise, there's no programmatic arbiter

Mechanical gates are bash scripts that execute BEFORE the tool call reaches the model. They cannot be bypassed by prompt manipulation, context degradation, or user override. They are `if` statements, not suggestions.

## Architecture

```
User/Agent requests: git push
       │
       ▼
┌─────────────────────────────────────┐
│ Claude Code PreToolUse hook fires   │
│ (hooks.json → pre-push-gate-check)  │
└──────────────────┬──────────────────┘
       │
       ▼
┌─────────────────────────────────────┐
│ Is this a git push command?         │
│ NO → exit 0 (allow)                 │
│ YES → run pre-push-gate             │
└──────────────────┬──────────────────┘
       │
       ▼
┌─────────────────────────────────────┐
│ pre-push-gate checks evidence files │
│                                     │
│ .code-forge/gate/tests-pass    ✓?   │
│ .code-forge/gate/stage1-clean  ✓?   │
│ .code-forge/gate/map-validated ✓?   │
│                                     │
│ Each file must:                     │
│ 1. Exist (gate has run)             │
│ 2. Match current HEAD (not stale)   │
└──────────────────┬──────────────────┘
       │
       ├── Any check fails → exit 1 (BLOCK with reason)
       │
       └── All pass → exit 0 (allow push)
```

## Evidence Files

Evidence is written by the review loop at the moment each gate passes:

| Gate | Written when | By command |
|---|---|---|
| `tests-pass` | `dotnet test` returns 0 exit code | `write-gate-evidence tests-pass` |
| `stage1-clean` | rubric-reviewer returns CLEAN | `write-gate-evidence stage1-clean` |
| `map-validated` | dependency-map-validator passes | `write-gate-evidence map-validated` |

Each evidence file contains:
```
GATE=stage1-clean
HEAD=abc1234
TIMESTAMP=2026-05-18T14:32:00Z
```

## Staleness Detection

Evidence is tied to a specific HEAD commit. If ANY commit is made after evidence is written (including fixups, amends, or new commits), the evidence is stale. The gate will block until the review loop runs again on the new HEAD.

This prevents:
- "Stage 1 was clean before my last edit" (stale — the edit might have introduced issues)
- "Tests passed 3 commits ago" (stale — subsequent commits might break them)
- "I validated the map yesterday" (stale — map is for a different state of the code)

## Bypassing (Intentional)

The gate can be intentionally bypassed by:
1. Deleting `.code-forge/gate/` directory (destructive, obvious in history)
2. Manually writing evidence files with current HEAD (requires knowing the mechanism)
3. Running git push outside of Claude Code (the hook is Claude Code–specific)

These are all intentional acts that require understanding what you're bypassing. The gate prevents ACCIDENTAL bypass (model drift, prompt pressure, context degradation). It does not prevent a determined human from pushing — that would be wrong to enforce.

## .gitignore

The `.code-forge/gate/` directory should be in `.gitignore` — evidence is local operational state, not source. Each machine tracks its own gates.

```
# Add to .gitignore
.code-forge/gate/
.code-forge/metrics.json
```

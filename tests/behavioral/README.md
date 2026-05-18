# Behavioral Tests

These tests validate that the LLM ACTUALLY FOLLOWS the documented protocols — not just that the documents are structurally correct.

## How they work

Each test:
1. Sets up a scenario (findings, code state, expected grouping)
2. Provides a prompt that simulates what the orchestrator would see
3. Defines assertions about what the LLM SHOULD do (group correctly, acknowledge before edit, etc.)

## Running

These are designed to be run with Claude Code in a controlled worktree:

```bash
bash tests/behavioral/run-coupled-group-test.sh
```

The test script:
1. Creates a temporary worktree with fixture code
2. Creates an active-groups.json with the test scenario
3. Invokes Claude Code with a specific prompt
4. Checks whether the mechanical gate fired correctly
5. Reports pass/fail

## What these prove

A passing behavioral test proves: given these findings and this code, the coupled-edit-gate correctly blocks independent edits and allows acknowledged-group edits.

A failing behavioral test proves: the mechanical gate has a bug, or the scenario is wrong.

These tests do NOT prove the LLM will group findings correctly (that's an LLM judgment call). They prove the GATE ENFORCEMENT works — which is the only part we can test deterministically.

## Why this matters

Structural tests (run-all-tests.sh) prove documents exist. Behavioral tests prove the gates work. Without behavioral tests, we're trusting that bash scripts written in one session actually function under real conditions.

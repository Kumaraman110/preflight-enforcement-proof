---
name: test-driven-development
description: Strict RED-GREEN-REFACTOR enforcement. Use when writing new functionality or fixing bugs that need regression protection. Ensures tests are written BEFORE implementation, preventing the "tests that always pass" anti-pattern.
argument-hint: [feature or behavior to implement]
allowed-tools: Read, Glob, Grep, Bash, Edit, Write
---

# /preflight:test-driven-development — RED-GREEN-REFACTOR

You are in TDD mode. Every piece of new functionality follows the cycle:

1. **RED:** Write a failing test that defines the desired behavior
2. **GREEN:** Write the minimum code to make the test pass
3. **REFACTOR:** Clean up without changing behavior (tests stay green)

## Step 0 — Environment Detection

If session context already contains `preflight active | mode=...` with config data, trust it. Skip to the HARD-GATE below.

If session context is empty or this skill was invoked cold:

1. Search for config: `.preflight/config.json` > `.cpsl/config.json` > `.forge.json` (in working directory, then up to 5 parent levels).
2. If found: extract `test.command`, `test.coverageBaseline`.
3. If not found: auto-detect test command (`dotnet test` if `.csproj`/`.sln`, `npm test` if `package.json`).
4. Check for `CLAUDE.md` at project root for test conventions (framework, naming, etc.).

<HARD-GATE>
Do NOT write implementation code before a failing test exists for the behavior you're about to implement. A test written after implementation proves nothing — it's always green because you wrote it to match what you already built.
</HARD-GATE>

## Rationalization Prevention

| Your thought | Why it's wrong |
|---|---|
| "This is too simple to TDD" | Simple code has simple tests. Write the 3-line test, then the 3-line implementation. 30 seconds. |
| "I'll write tests after, I know what I'm building" | Tests-after are confirmation bias artifacts. They test what you built, not what you intended. |
| "The existing code doesn't have tests, TDD doesn't apply" | TDD applies to YOUR new code. Existing untested code is tech debt you didn't create. |
| "I need to see the shape of the code first" | Write the test first — it DEFINES the shape. The test is your design tool. |
| "TDD slows me down" | TDD front-loads 60 seconds per behavior. Skipping it back-loads 5+ minutes of debugging per defect. |

## The Cycle (Enforced)

### RED Phase

1. Identify the next atomic behavior to implement (one assertion, one behavior)
2. Write a test that ASSERTS that behavior exists
3. Run the test — it MUST fail (compile error counts as failing)
4. If it passes without implementation → your test is wrong (testing nothing)

### GREEN Phase

5. Write the MINIMUM code to make the failing test pass
6. Do not write more than the test demands
7. Do not optimize, refactor, or "make it nice"
8. Run tests — the new test passes, all existing tests still pass

### REFACTOR Phase

9. Now improve: extract methods, rename, reduce duplication
10. Run tests after each refactoring step — all must stay green
11. If a test breaks during refactoring, you changed behavior (undo and redo more carefully)

### Then: next RED

12. Identify the next behavior. Write the next failing test. Repeat.

## Stack Conventions

Stack-specific conventions are read from CLAUDE.md (test framework, mocking library, assertion library). The team's standards govern test framework choice; this skill enforces the RED-GREEN-REFACTOR discipline regardless of stack.

- **Coverage:** Track with each GREEN phase. Coverage should increase monotonically.
- **Naming:** Follow the team's test naming convention from CLAUDE.md (e.g., `MethodName_Scenario_ExpectedBehavior`).

## What "Minimum Code" Means

GREEN phase means: make this ONE test pass. Not "make this test pass AND handle edge cases AND add logging AND wire up DI." Those are future RED-GREEN cycles.

Example cycle:
```
RED:   Test that GetAccount returns 404 when MP number doesn't exist
GREEN: if (mpNumber == null) return NotFound();  // literal minimum
RED:   Test that GetAccount returns account data for valid MP number
GREEN: Add the actual lookup logic
RED:   Test that GetAccount sanitizes log output
GREEN: Add LogSanitizer.Sanitize() call
```

Each cycle is 1-3 minutes. Small cycles = fast feedback = fewer bugs.

## When to Exit TDD Mode

- The feature is complete (all planned behaviors have tests)
- Coverage meets baseline (from project config `test.coverageBaseline`)
- All tests pass

Then: invoke `/preflight:self-review` to validate the implementation against the rubric.

Begin. What is the first behavior to test?

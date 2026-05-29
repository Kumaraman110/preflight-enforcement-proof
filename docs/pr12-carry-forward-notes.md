# PR 12 — Carry-Forward Notes

## Pre-run context (preserved from arc)

### Dependency-map blind spots (ref commit 4a66e3c)
- Factory-lambda DI, event-bus, config-binding not fully traced by current map tooling.
- Validator catches ~60% of dependency issues.
- Non-reproducibility property documented: same input can yield different map output across runs.
- Named trigger condition for building AST extraction (not yet built).

### Boris-style review — bloat candidates (~1500 lines)
- resolve-config.sh + extract-overrides.sh: 632 lines, 1 consumer.
- 6 orphan lib/*.md files: ~403 lines.
- 5 empty test directories.
- docs/rubric-edit-process.md: 287 lines, never executed.
- ~150 lines retry/rate-limit in resolve-review-thread.sh.
- Verdict: simplicity FAIL, minimal-impact FAIL, verification loops STRONG.

### Graphify finding
- GPS-Decide is a god node with zero behavioral test coverage.
- Only new finding manual analysis missed.

### Boris's hardest question
"What is the feedback loop on the framework itself?" PR 12 produces the first metrics.json with real data.

### Prior-gen SessionToken migration
- Branch `feature/migrate-sessiontoken` at HEAD 7699a2bc.
- Reached final state: 5 documented intentional parity deviations, 9 Stage 3a corrections.
- Reverted at e7826aab for authorization reasons, not quality.
- Local files deleted; only branch history exists.
- PR 12 is preflight's independent attempt — post-hoc comparison only.

### Deferred decisions (NOT for this run)
- Delete bloat candidates.
- Build map feedback signal.
- Build framework-metrics consumer.
- All wait for PR 12 evidence.

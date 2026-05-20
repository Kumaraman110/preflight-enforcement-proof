# preflight Review System Tests

Tests the review system itself — not service code.

## Why these exist

Every change to the rubric, operative rules, copilot-loop classification, or coupling logic is a hypothesis. Without tests, the first feedback comes from running on a real service (expensive, slow, no rollback). These tests give 30-second validation before any change takes effect.

## Suites

| Suite | What it validates | When to run |
|---|---|---|
| `stage1` | Rubric has detection patterns for known-bad code | After any rubric edit |
| `operative` | Confidence threshold wiring (Survived counts, severity promotion) | After changing code-reviewer or copilot-loop operative rule handling |
| `coupling` | Structural coupling signals detected correctly | After changing dependency-map-validator |
| `crosscheck` | CONTRADICTS_RUBRIC classification exists and is ordered correctly | After changing copilot-loop stability filter |

## Running

```bash
# All suites
bash tests/run-all-tests.sh

# Single suite
bash tests/run-all-tests.sh stage1
bash tests/run-all-tests.sh coupling
bash tests/run-all-tests.sh crosscheck
bash tests/run-all-tests.sh operative
```

## Adding fixtures

1. Create a `.cs` file in the appropriate `fixtures/` directory
2. Comment the file with the rubric section it should trigger
3. Create a matching `.json` in `expected/` with the expected findings
4. Run the suite — if it fails, either the fixture is wrong or the rubric is incomplete

## Design principle

These tests verify the STRUCTURE of the review system (does the rubric cover X? does the copilot-loop have step Y?). They do NOT invoke the LLM — that would make them non-deterministic. LLM behavior is tested via the fixtures: if the rubric has the detection pattern, the reviewer WILL find it (because the reviewer walks the rubric exhaustively by design).

# Severity Matrix

Default severity assignments for the code-reviewer agent. Project-specific rubrics can override these by specifying severity inline with each section.

## Severity Levels

| Level | Meaning | Gate Behavior |
|---|---|---|
| `blocker` | Must fix before push. Security vulnerability, data exposure, or correctness issue that would fail external review. | Blocks push |
| `major` | Must fix before push. Significant quality issue that external review will flag. | Blocks push |
| `minor` | Optional fix. Style, hygiene, or low-risk improvement. Does not block push. | Advisory |
| `info` | Observation. Not a finding — a note for the developer's awareness. | Informational |

## Default Assignments by Category

| Category | Default Severity |
|---|---|
| CWE-* security finding | `blocker` |
| OWASP Top 10 match | `blocker` |
| Hardcoded secret | `blocker` |
| Auth bypass / validation skip in non-dev | `blocker` |
| Container running as root | `blocker` |
| Async correctness (deadlock risk) | `major` |
| Missing CancellationToken propagation | `major` |
| API contract / wire-format mismatch | `major` |
| Missing tests on new code | `major` |
| Coverage regression below baseline | `major` |
| Missing input validation on public API | `major` |
| Service lifetime mismatch | `major` |
| Unbounded query / missing pagination | `major` |
| Missing health endpoints | `major` |
| Style / naming / formatting | `minor` |
| Doc drift | `minor` |
| Project file cleanup | `minor` |
| Missing Polly resilience handler | `minor` |
| Observation / suggestion | `info` |

## Calibration via Rubric Edits

Severity calibration happens through the batched rubric-edit PR process. When calibration-log entries identify severity mismatches (e.g., a section marked blocker that Copilot consistently does not flag), those entries are promoted into rubric revisions with corrected severity at the next rubric-edit cadence. The rubric's inline severity declarations always take precedence over this default matrix.

Code-reviewer does NOT read capture files for runtime severity overrides — only the rubric is authoritative for detection and severity.

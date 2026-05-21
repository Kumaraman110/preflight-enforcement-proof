---

# PREFLIGHT CONTRACT AUDIT — Complete Interface Map

---

## CATEGORY 1: STATE FILE CONTRACTS

---

### INTERFACE: .preflight/config.json (Consumer Project Config)

**PRODUCER:** Human (team member creates this file in their project)
**CONSUMER(S):**
- `hooks/session-start` (lines 23-56) — reads mode, rubric, capture paths
- `skills/fix-and-close/SKILL.md` (lines 59-79) — reads all config fields
- `skills/migrate-service/SKILL.md` (lines 21-31) — reads mode, rubric, branch, migration fields
- `skills/self-review/SKILL.md` (lines 18-24) — reads mode, rubric, branch, test, loop, capture
- `skills/scaffold-api/SKILL.md` (lines 29-34) — reads mode, rubric, branch
- `agents/copilot-review-loop.md` (lines 24-37) — reads review.*, loop.*, capture.*, branch.*
- `lib/project-detector.md` (lines 7-53) — canonical schema reference
- `lib/skill-bootstrap.md` (lines 7-27) — detection logic for all skills

**CURRENT IMPLICIT CONTRACT:**
```json
{
  "mode": "migration" | "api-new" | "generic",
  "rubric": "path/to/rubric.md" | null,
  "capture": {
    "calibrationLog": "path",
    "checklistAdditions": "path",
    "falsePositives": "path"
  },
  "review": {
    "copilotReviewerLogin": "string",
    "pollIntervalSeconds": number,
    "initialWaitSeconds": number
  },
  "loop": {
    "rubricEditCadence": number,
    "maxStage1Iterations": number,
    "maxStage2Iterations": number,
    "maxRubricTokens": number,
    "maxCaptureTokens": number,
    "oscillation": {
      "stopOnSameFilesAcrossConsecutiveIterations": bool,
      "stopOnSameLineModifiedConsecutively": number
    }
  },
  "branch": { "base": "string", "remote": "string" },
  "test": { "command": "string" | null, "coverageBaseline": number | null },
  "migration": {
    "legacyRepoPath": "string" | null,
    "servicesRoot": "string",
    "referenceService": "string" | null
  }
}
```

**EVIDENCE:** `lib/project-detector.md:16-53` has the canonical schema. `defaults/config-template.json:1-47` has the template.

**GAPS:**
- `loop.maxStage1Iterations` and `loop.maxStage2Iterations` appear in `project-detector.md:31-32` but NOT in `config-template.json`. Template is missing these fields.
- `loop.maxRubricTokens` and `loop.maxCaptureTokens` in `project-detector.md:33-34` — not referenced by any consumer skill; unclear what reads them.
- `migration.servicesRoot` in both places but no skill reads it explicitly (migrate-service uses `legacyRepoPath` + service name).
- `branch.migrationPrefix` referenced in `skills/migrate-service/SKILL.md:59` but not in the schema or template.

**PRIORITY: HIGH** — everything references this; schema drift causes cascading misreads.

---

### INTERFACE: dependency-map.json

**PRODUCER:** `agents/discovery-analyst.md` (lines 87-115)
**CONSUMER(S):**
- `skills/fix-and-close/SKILL.md` (lines 100-101) — reads for coupling analysis
- `lib/dependency-map-validator.md` (lines 10-107) — validates structure
- `hooks/pre-push-gate` (line 46) — checks existence to decide whether map-validated gate applies
- `skills/migrate-service/SKILL.md` (lines 144-159) — orchestrates production and validation

**CURRENT IMPLICIT CONTRACT:**
```json
{
  "files": {
    "<relative-path>": {
      "imports": ["<relative-path>", ...],
      "injectedBy": ["<relative-path>", ...],
      "callsInto": ["<type-name>", ...],
      "calledBy": ["<relative-path>", ...]
    }
  },
  "couplingGroups": [
    {
      "reason": "string",
      "files": ["<relative-path>", ...]
    }
  ],
  "independent": ["<relative-path>", ...]
}
```

**EVIDENCE:** `agents/discovery-analyst.md:92-113` (the JSON example).

**GAPS:**
- The validator (`lib/dependency-map-validator.md:19`) uses `jq -r '.independent[]'` and `jq -r '.couplingGroups[].files[]'` — confirms the array structure.
- But `fix-and-close/SKILL.md:100` references it as `<service-folder>/dependency-map.json` while `pre-push-gate:46` looks for it with `find . -name "dependency-map.json" -maxdepth 2`. Placement path is ambiguous.
- No schema for what types are valid in `callsInto` (types? files? namespaces?). Discovery-analyst's example shows `"HttpClient"` (a type name) but validator step 1 grepping for `using` statements would only catch namespaces.

**PRIORITY: HIGH** — wrong map structure causes cascading regressions in fix-and-close.

---

### INTERFACE: Gate Evidence Files (.preflight/gate/{tests-pass, stage1-clean, map-validated})

**PRODUCER:** `hooks/write-gate-evidence` (lines 1-43)
**CONSUMER(S):** `hooks/pre-push-gate` (lines 21-37)

**CURRENT IMPLICIT CONTRACT:**
```
GATE=<gate-name>
HEAD=<git-commit-sha>
TIMESTAMP=<ISO-8601-datetime>
```
Where `gate-name` is one of: `tests-pass`, `stage1-clean`, `map-validated`.

**EVIDENCE:**
- Producer: `hooks/write-gate-evidence:39-43` writes the file with `cat > "$GATE_DIR/$GATE_NAME" <<EOF`
- Consumer: `hooks/pre-push-gate:31` reads with `grep "^HEAD=" "$GATE_DIR/$file" | cut -d= -f2`

**GAPS:**
- Format is simple key=value, no JSON. Robust enough but no validation that HEAD is actually a valid sha (could be "unknown" per line 36 of write-gate-evidence).
- `map-validated` gate is conditional: only checked if a `dependency-map.json` exists anywhere within 2 levels (pre-push-gate:46). First migration won't have one.

**PRIORITY: MEDIUM** — simple and well-isolated; unlikely to drift.

---

### INTERFACE: Active Groups File (.preflight/gate/active-groups.json)

**PRODUCER:** `hooks/write-active-groups` (lines 1-20)
**CONSUMER(S):**
- `hooks/coupled-edit-gate` (lines 27-78) — reads to enforce acknowledgment
- `hooks/write-group-ack` (lines 14-48) — reads and modifies

**CURRENT IMPLICIT CONTRACT:**
```json
[
  {
    "files": ["relative/path/A.cs", "relative/path/B.cs"],
    "findings": ["§4.2 on A:15", "§4.3 on B:22"],
    "acknowledged": false
  }
]
```
Empty array `[]` means no active groups (gates cleared).

**EVIDENCE:**
- Producer: `hooks/write-active-groups:19` writes raw JSON argument to file
- Consumer (coupled-edit-gate): `coupled-edit-gate:58` uses jq to `select(.acknowledged == false) | select(.files[] | contains($fp))`
- Consumer (write-group-ack): `write-group-ack:30-31` uses jq to set `.[$idx].acknowledged = true`

**GAPS:**
- `coupled-edit-gate:50` uses `basename "$FILE_PATH"` for initial quick-check grep. Could false-match files with same basename in different directories.
- The `findings` array content is human-readable strings with no machine-parseable structure. Only used for display; no consumer parses it.
- File path matching in `coupled-edit-gate:58-60` uses `contains($fp)` which is a substring match, not exact. Could produce false matches (`"Services/A.cs"` contains in `"Tests/Services/A.cs"`).

**PRIORITY: HIGH** — path matching bugs in the edit gate could either over-block or under-block.

---

### INTERFACE: Capture Files (calibration-log.md, checklist-additions.md, false-positives.md)

**PRODUCER:** `agents/copilot-review-loop.md` (lines 153-273)
**CONSUMER(S):**
- `agents/code-reviewer.md` (lines 25-48) — reads for operative detection rules and calibration context
- `skills/fix-and-close/SKILL.md` (lines 200-221) — references operative capture rules
- Batched rubric-edit PR process (human-initiated, references capture entries)

**CURRENT IMPLICIT CONTRACT — calibration-log.md (Bucket 1):**
```markdown
## <ISO date> — §<section> missed by Stage 1

**PR:** <url> · **File:** <path>:<line>
**Survived:** <integer>

**Copilot said:** <one sentence>

**Why Stage 1 missed it:** <gap description>

**IMMEDIATE DETECTION RULE:**
Flag as `<severity>` if: <boolean condition>

**BAD (literal anti-pattern):**
\`\`\`csharp
<code>
\`\`\`

**GOOD (required coexistence):**
\`\`\`csharp
<code>
\`\`\`
```

**CURRENT IMPLICIT CONTRACT — checklist-additions.md (Bucket 2):**
```markdown
## <ISO date> — Candidate category: <short name>

**PR:** <url> · **File:** <path>:<line>

**Copilot said:** <one sentence>

**Pattern:** <anti-pattern description>

**Detection signal:** <how Stage 1 would catch it>

**Suggested severity:** blocker | major | minor — <justification>

**Confidence:** high | medium | low
```

**CURRENT IMPLICIT CONTRACT — false-positives.md (Bucket 3):**
```markdown
## <ISO date> — §<section> flagged but external review disagrees

**PR:** <url> · **File:** <path>:<line>

**Stage 1 said:** <finding>

**External said:** <comment or "did not flag">

**Suggested loosening:** <more precise signal>
```

**CURRENT IMPLICIT CONTRACT — checklist-additions.md Deferred section (Bucket 4):**
```markdown
### <ISO date> — Deferred: <short name>

**PR:** <url> · **File:** <path>:<line>

**Comment:** <one sentence>

**Why deferred:** <why this is judgment, not rule>
```

**EVIDENCE:** `agents/copilot-review-loop.md:160-240` defines all four templates.

**GAPS:**
- **Bucket 5 (pattern-capture)** writes to `docs/review/generation-spec-candidates.md` (copilot-review-loop.md:251) — this is NOT configured in `config.json` capture paths. No config field points to it.
- The `code-reviewer.md:25-48` reads `IMMEDIATE DETECTION RULE` blocks and uses `**Survived:**` count + `**Confidence:**` field to determine severity. But the template shows `Survived` without `Confidence` (confidence is only on Bucket 2 entries). The code-reviewer's confidence threshold (lines 36-46) references both fields on operative rules — the producer only writes `Survived` on Bucket 1 entries.
- Bucket 2 entries do NOT have `IMMEDIATE DETECTION RULE` blocks (they're candidates for the NEXT rubric edit). But the code-reviewer reads capture files looking for `IMMEDIATE DETECTION RULE` — so only Bucket 1 entries act as operative rules. This is correct but the relationship is implicit.

**PRIORITY: HIGH** — the operative-rule mechanism is the core self-improvement contract.

---

### INTERFACE: Metrics File (.preflight/metrics.json)

**PRODUCER:** `skills/fix-and-close/SKILL.md` (lines 185-193)
**CONSUMER(S):**
- `lib/metrics.md` (defines the schema, lines 12-50)
- `agents/discovery-analyst.md` — mentioned as reader for trend analysis (`lib/metrics.md:95`)
- `agents/code-reviewer.md` — mentioned as reader for section weighting (`lib/metrics.md:96`)

**CURRENT IMPLICIT CONTRACT:**
```json
{
  "runs": [
    {
      "timestamp": "ISO-8601",
      "service": "string",
      "branch": "string",
      "skill": "string",
      "stage1": {
        "iterations": number,
        "findingsPerIteration": [number],
        "capHit": bool,
        "couplingGroupsIdentified": number,
        "couplingGroupSizes": [number],
        "independentFindings": number,
        "validatorWarnings": number,
        "durationSeconds": number
      },
      "stage2": {
        "iterations": number,
        "findingsPerIteration": [number],
        "capHit": bool,
        "stableFindings": number,
        "trivialStableFindings": number,
        "unstableFindings": number,
        "pollWaitSeconds": number,
        "durationSeconds": number
      },
      "capture": {
        "inRubricButMissed": number,
        "newCategory": number,
        "falsePositive": number,
        "humanJudgment": number,
        "patternCapture": number
      },
      "outcome": "SUCCESS" | "CAPPED" | "STUCK" | "DIVERGING" | "ERROR",
      "totalDurationSeconds": number
    }
  ]
}
```

**EVIDENCE:** `lib/metrics.md:12-50` (full schema example).

**GAPS:**
- Discovery-analyst and code-reviewer are listed as READERS but neither agent's definition file references metrics.json. The consumption is aspirational (documented in lib/metrics.md) but not implemented in the agent definitions.
- `.gitignore` guidance exists (`lib/metrics.md:112-114`) but no `.gitignore` file in the framework ensures this.

**PRIORITY: MEDIUM** — important for proving the system works, but not on the critical path for correctness.

---

### INTERFACE: Generation Spec Candidates (docs/review/generation-spec-candidates.md)

**PRODUCER:** `agents/copilot-review-loop.md` (lines 242-275, Bucket 5)
**CONSUMER(S):** Human (during batched rubric-edit PR), potentially future automation

**CURRENT IMPLICIT CONTRACT:**
```markdown
## <ISO date> — Candidate pattern: <short name>

**PR:** <url> · **Files:** <path1>, <path2>

**Problem:** <what rubric section this prevents>

**Rubric sections:** §<N.N>, §<N.N>

**Pattern (verified working — passed Stage 1 + Copilot):**
\`\`\`csharp
<code with /* ADAPT */ points>
\`\`\`

**Adaptation points:**
- `/* ADAPT: <description> */` — <what varies>

**Confidence:** high | medium

**Promotion criteria:** 3+ candidates across different services → promote to generation spec
```

**EVIDENCE:** `agents/copilot-review-loop.md:253-273`

**GAPS:**
- No config path for this file. It's hardcoded as `docs/review/generation-spec-candidates.md` in the copilot-review-loop agent definition.
- No consumer skill or agent reads this file automatically. It's human-consumed only.

**PRIORITY: LOW** — write-only, human-consumed. Drift is low-risk.

---

## CATEGORY 2: SUB-AGENT I/O CONTRACTS

---

### INTERFACE: code-reviewer (Stage 1) I/O

**INPUT (from parent/orchestrator):**
- Diff scope context (which files changed, base ref)
- The rubric (discovered at runtime from config or defaults)
- Capture files (for operative detection rules)
- No structured arguments — invoked via Agent tool with free-form prompt

**OUTPUT:**
```
## Stage 1 Review Result

**Overall:** CLEAN | NEEDS_FIXES | ERROR

**Files reviewed:** N
**Findings:** total
- Blocker: n
- Major: n
- Minor: n
- Info: n
- Completeness: n

**Summary:** one or two sentences.

**Findings (JSON):**
```json
[
  {
    "file": "path/to/File.cs",
    "line": 47,
    "severity": "blocker",
    "category": "§X.Y",
    "dimension": "correctness",
    "issue": "What is wrong and why.",
    "suggestion": "Exact change to make."
  }
]
```

**ERROR:**
```
## Stage 1 Review Result

**Overall:** ERROR

**Reason:** what went wrong.
```

**EVIDENCE:** `agents/code-reviewer.md:158-210` (output format definition).

**GAPS:**
- Input is entirely unstructured (free-form prompt in Agent tool). No schema for what the invoker must provide.
- The `dimension` field can be `"correctness"` or `"completeness"`. The `category` field uses `"§X.Y"` for correctness and `"completeness:*"` for completeness findings (code-reviewer.md:200-205).
- `line` can be `null` for completeness findings (code-reviewer.md:189).
- No explicit listing of valid severity values in the output spec (implied: blocker, major, minor, info).

**PRIORITY: HIGH** — this is the most-invoked sub-agent; ambiguous output parsing causes fix failures.

---

### INTERFACE: copilot-review-loop (Stage 2) I/O

**INPUT:** Free-form prompt via Agent tool. Expects:
- PR to already be pushed (or will create one)
- Project config accessible at runtime

**OUTPUT:**
```
## Stage 2 Result — Iteration N

**Status:** SUCCESS | NEEDS_PARENT_FIXES | CAPPED | STUCK | DIVERGING | FAILED | ERROR

**PR:** <url> · **Iteration:** N · **Comments this round:** M

**Capture summary:**
- in-rubric-but-missed: x
- new-category: y
- false-positive: z
- human-judgment: w
- pattern-capture: p

**Findings (JSON):**
```json
{
  "status": "...",
  "pr": "<url>",
  "iteration": N,
  "copilotComments": [...],
  "captureFilesWritten": [...],
  "stuckReason": null,
  "error": null
}
```

**EVIDENCE:** `agents/copilot-review-loop.md:290-318` (output format). Status codes at lines 69-77.

**GAPS:**
- `copilotComments` array structure is unspecified (what fields per comment?). Step 4 (line 59-62) shows the raw `gh api` fields: `{id, path, line, original_line, body, created_at}` — but the output JSON doesn't say which of these it includes.
- Each comment in the returned JSON should include `"stability"` classification (`stable`, `trivial-stable`, `unstable`, `contradicts-rubric`) per lines 143-148, but the output format example (lines 307-316) doesn't show this field explicitly.
- `captureFilesWritten` — just paths? Or paths + entry counts?

**PRIORITY: HIGH** — the parent (fix-and-close) must parse this to decide what to fix vs surface.

---

### INTERFACE: discovery-analyst I/O

**INPUT:** Free-form prompt. Expects:
- Path to codebase to analyze
- Whether this is migration or net-new

**OUTPUT:**
1. Markdown discovery report (lines 61-85)
2. `dependency-map.json` file written to disk (lines 87-115)

**EVIDENCE:** `agents/discovery-analyst.md:60-115`

**GAPS:**
- Output is BOTH a text report AND a file write. No status code like the other agents.
- How does the orchestrator know the map was written successfully? Verification discipline says "check file exists and parses" but the agent itself has no DONE/BLOCKED status.
- Readiness score output structure is a markdown table, not JSON. Harder to consume programmatically if ever needed.

**PRIORITY: MEDIUM** — less frequent invocation (once per migration), and verification-discipline covers the gap.

---

### INTERFACE: implementer I/O

**INPUT:** Structured fix brief:
```
## Fix Brief — Round N, Group X

**Files to modify:** [list]
**DO NOT modify other files.**

**Findings to address:** [numbered list]
**Coupling reason:** [string]
**Constraint:** [string — typically "dotnet build + dotnet test must pass"]
**Generation spec pattern to use:** [code or "N/A"]
**What was tried previously:** [description or "nothing"]
```

**OUTPUT:** One of:
```
## Implementer Result: DONE

**Files modified:** [list with line ranges]
**Findings addressed:** [list by number]
**Approach:** [1-2 sentences]
**Tests:** [pass/fail count]
```
or:
```
## Implementer Result: BLOCKED

**Reason:** [string]
**Attempted:** [description]
**Suggestion:** [what orchestrator might try]
```

**EVIDENCE:** `agents/implementer.md:14-63`

**GAPS:**
- Input is documented as structured but delivered via free-form Agent tool prompt (no enforcement).
- "Tests: [pass/fail count]" — is this `X passed, Y failed` or `X/Y` or what? Unstandardized.
- DONE is explicitly NOT trusted by the orchestrator (verification-discipline.md:20) — but the output format doesn't include test output as evidence. The orchestrator must re-run independently.

**PRIORITY: MEDIUM** — the verification-discipline layer compensates for output ambiguity.

---

## CATEGORY 3: SKILL HANDOFF CONTRACTS

---

### INTERFACE: /migrate-service → /fix-and-close

**INVOCATION:** Skill invocation via Skill tool (or equivalent internal dispatch)
**ARGUMENTS PASSED:** Commit-message hint string (e.g. `feat(sessiontoken): migrate to .NET 10`)
**RETURN SIGNAL EXPECTED:** fix-and-close's structured status (DONE, CAPPED, STUCK, DIVERGING, BLOCKED, ERROR)
**FAILURE HANDLING:** Surface to user per fix-and-close's termination conditions

**EVIDENCE:** `skills/migrate-service/SKILL.md:161-172` ("invoke `/preflight:fix-and-close`... Pass the commit-message hint")

**GAPS:**
- No explicit handoff of the dependency-map.json path (fix-and-close finds it by convention at `<service-folder>/dependency-map.json`)
- No explicit handoff of Phase 1 outputs for PR description (migrate-service says "Include Phase 1 outputs in the PR description" but doesn't specify HOW to pass this to fix-and-close)

**PRIORITY: MEDIUM**

---

### INTERFACE: /fix-and-close → code-reviewer

**INVOCATION:** Agent tool dispatch with `subagent_type: "code-reviewer"`
**ARGUMENTS PASSED:** Free-form prompt including diff scope
**RETURN SIGNAL:** Structured markdown output (CLEAN/NEEDS_FIXES/ERROR + findings JSON)
**FAILURE HANDLING:** ERROR → abort and surface to user

**EVIDENCE:** `skills/fix-and-close/SKILL.md:94-95` ("Invoke `code-reviewer` sub-agent. Always.")

**GAPS:** Same as code-reviewer I/O contract above — no structured input schema.

**PRIORITY: HIGH** (same as code-reviewer I/O)

---

### INTERFACE: /fix-and-close → copilot-review-loop

**INVOCATION:** Agent tool dispatch with `subagent_type: "copilot-review-loop"`
**ARGUMENTS PASSED:** Free-form prompt with PR context
**RETURN SIGNAL:** Status codes (SUCCESS/NEEDS_PARENT_FIXES/CAPPED/STUCK/DIVERGING/FAILED/ERROR) + findings JSON with stability categories
**FAILURE HANDLING:** Per status code (fix-and-close/SKILL.md:157-172)

**EVIDENCE:** `skills/fix-and-close/SKILL.md:155-172`

**GAPS:** Same as copilot-review-loop I/O contract.

**PRIORITY: HIGH**

---

### INTERFACE: /fix-and-close → implementer

**INVOCATION:** Agent tool dispatch with structured fix brief
**ARGUMENTS PASSED:** Fix Brief markdown (files, findings, coupling reason, constraint, gen-spec, prior attempts)
**RETURN SIGNAL:** DONE or BLOCKED with structured fields
**FAILURE HANDLING:** BLOCKED → re-scope or escalate (fix-and-close/SKILL.md:131-133)

**EVIDENCE:** `skills/fix-and-close/SKILL.md:123-133`

**GAPS:** Same as implementer I/O contract.

**PRIORITY: MEDIUM**

---

### INTERFACE: /self-review → code-reviewer

**INVOCATION:** Agent tool dispatch
**ARGUMENTS PASSED:** Diff scope context
**RETURN SIGNAL:** Same CLEAN/NEEDS_FIXES/ERROR output
**FAILURE HANDLING:** ERROR → surface to user, exit (self-review/SKILL.md:57)

**EVIDENCE:** `skills/self-review/SKILL.md:52-57`

**GAPS:** Same as code-reviewer I/O. Self-review additionally does a verification check: "verify the sub-agent's 'Files reviewed' list matches current diff" (line 55).

**PRIORITY: HIGH** (same underlying contract)

---

### INTERFACE: /scaffold-api → /fix-and-close

**INVOCATION:** Same as migrate-service → fix-and-close
**ARGUMENTS PASSED:** Commit-message hint
**RETURN SIGNAL:** Same structured status

**EVIDENCE:** `skills/scaffold-api/SKILL.md` (would need full read to confirm; first 50 lines show same Step 0 pattern)

**GAPS:** Not explicitly documented in scaffold-api (would need full read). Inferred from structural similarity.

**PRIORITY: LOW** (scaffold-api uses the same machinery)

---

## CATEGORY 4: HOOK EVENT CONTRACTS

---

### INTERFACE: session-start hook

**TRIGGER:** `SessionStart` event (hooks.json:3-14)
**INPUT:** None (no arguments from Claude Code)
**SIDE EFFECTS:**
- Searches for config file
- Reads mode, rubric, capture count
- Loads routing skill content (strips YAML frontmatter)
- Outputs JSON: `{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"<escaped-string>"}}`

**OUTPUT INJECTED INTO SESSION:**
```
preflight active | mode=<mode> | config=<path> | rubric=<path> | N capture files active

<routing skill content (SKILL.md body without frontmatter)>
```

**EVIDENCE:** `hooks/session-start:60-89`

**GAPS:**
- Line 76 `sed` to strip frontmatter may fail on Windows if file has CRLF line endings (bash on Windows uses CRLF files).
- Line 83 escaping for JSON is brittle (sed-based). A single unescaped backslash or quote in the routing content would produce invalid JSON.
- The consumer (skills' Step 0) checks for the presence of `preflight active | mode=...` as a string in session context (e.g., `self-review/SKILL.md:16`). If the hook's output format changes, every skill's Step 0 detection regex breaks.

**PRIORITY: HIGH** — hook output format is read by every skill.

---

### INTERFACE: pre-push-gate-check hook (PreToolUse on Bash)

**TRIGGER:** Any `Bash` tool call (hooks.json:18-27)
**INPUT:** `$TOOL_INPUT` — the raw command string
**SIDE EFFECTS:**
- Checks if command contains `git push`
- If yes: delegates to `pre-push-gate`
- If no: exits 0 (allow)

**EVIDENCE:** `hooks/pre-push-gate-check:16-24`

**GAPS:**
- Regex `'(^|&&|\|\||;)\s*git\s+push'` won't match `git push` preceded by environment variable assignments or wrapped in subshells.
- The check passes `$TOOL_INPUT` as the raw command but hooks.json passes `"$TOOL_INPUT"` (quoted). Unclear if Claude Code passes the JSON tool parameters or the extracted command string.

**PRIORITY: MEDIUM** — false negatives (missed push) are low-probability; false positives (blocking non-push) impossible (only triggers on regex match).

---

### INTERFACE: coupled-edit-gate hook (PreToolUse on Edit)

**TRIGGER:** Any `Edit` tool call (hooks.json:28-38)
**INPUT:** `$TOOL_INPUT` — JSON with `file_path` field
**SIDE EFFECTS:**
- Reads `.preflight/gate/active-groups.json`
- Checks if edited file is in an unacknowledged group
- Exit 0 (allow) or Exit 1 (block with reason)

**EVIDENCE:** `hooks/coupled-edit-gate:1-99`

**GAPS:**
- Same path-matching issues as active-groups contract (basename grep, substring contains).
- Input assumed to be JSON with `file_path` field; fallback is grep extraction; final fallback is raw string. Multiple parsing paths = multiple possible failure modes.

**PRIORITY: HIGH** — this is the mechanical enforcement of the coupled-group protocol.

---

### INTERFACE: write-gate-evidence hook

**TRIGGER:** Called explicitly by the orchestrator skill (not an event hook)
**INPUT:** `$1` = gate name (one of: `tests-pass`, `stage1-clean`, `map-validated`)
**SIDE EFFECTS:** Writes `.preflight/gate/<gate-name>` with GATE/HEAD/TIMESTAMP

**EVIDENCE:** `hooks/write-gate-evidence:1-43`

**GAPS:** None significant — simple, well-bounded.

**PRIORITY: LOW**

---

### INTERFACE: write-active-groups hook

**TRIGGER:** Called explicitly by orchestrator
**INPUT:** `$1` = JSON array string
**SIDE EFFECTS:** Writes to `.preflight/gate/active-groups.json`

**EVIDENCE:** `hooks/write-active-groups:1-20`

**GAPS:**
- No validation that the JSON is well-formed. If the orchestrator passes malformed JSON, the coupled-edit-gate will fail to parse and either allow everything (dangerous) or block everything (annoying).

**PRIORITY: MEDIUM**

---

### INTERFACE: write-group-ack hook

**TRIGGER:** Called explicitly by orchestrator
**INPUT:** `$1` = 0-based group index
**SIDE EFFECTS:** Sets `acknowledged: true` on that group in active-groups.json

**EVIDENCE:** `hooks/write-group-ack:1-50`

**GAPS:**
- Index out-of-bounds produces a Python exception but doesn't clearly communicate back to the calling agent what went wrong.

**PRIORITY: LOW**

---

## CATEGORY 5: RUBRIC CONTRACT

---

### INTERFACE: Rubric File Structure

**FILES:**
- `defaults/rubric-generic.md` — cross-cutting .NET concerns
- `defaults/rubric-migration.md` — .NET Framework → modern .NET migration-specific
- `defaults/rubric-api-design.md` — net-new API design rules
- Project-specific rubric (at path from config)

**CURRENT STRUCTURAL SHAPE:**
```markdown
# <Rubric Title>

---

## §<ID> <Category Name>

### §<ID>.<sub> <Finding Name>
**Detect:** <pattern description>
**Severity:** blocker | major | minor
**BAD:** (optional)
\`\`\`csharp
<anti-pattern code>
\`\`\`
**GOOD:** (optional)
\`\`\`csharp
<correct pattern>
\`\`\`
**Fix:** <fix direction>

---
```

**EVIDENCE:** `defaults/rubric-migration.md:9-78` (shows §M1, §M1.1, §M1.2, §M2, §M2.1, §M2.2, §M3, §M3.1, §M3.2, §M4, §M4.1, §M4.2, §M4.3). `defaults/rubric-generic.md:7-60` (shows §1, §1.1-1.3, §2, §2.1-2.4, §3, §3.1-3.2).

**CONSUMERS:**
- `agents/code-reviewer.md` — walks every section against every changed file
- `agents/copilot-review-loop.md:114-137` (Step 7.5) — pattern-matches suggestion target state against `BAD` blocks
- `lib/severity-matrix.md:40-43` — calibration override from capture entries takes precedence

**HOW CAPTURE ENTRIES REFERENCE THE RUBRIC:**
- By section ID: `§M4.3`, `§2.1`, `§A1.2` (matched by string pattern)
- The code-reviewer output uses `"category": "§X.Y"` (code-reviewer.md:180)
- Operative rules in calibration-log reference `§<section>` in their header

**RUBRIC-EDIT CADENCE MECHANICS:**
- Configured at `loop.rubricEditCadence` (default 5)
- After N migrations, copilot-review-loop proposes a rubric-edit PR
- Entries from capture files become new sections or revisions
- Human reviews and merges

**GAPS:**
- ~~Section IDs are NOT globally unique across rubrics: generic uses `§1`, `§2`...; migration uses `§M1`, `§M2`...; API design uses `§A1`, `§A2`... If a project uses both generic + migration rubric, findings reference which? The code-reviewer walks "every applicable section" but doesn't namespace its output categories by which rubric the section came from.~~ **RESOLVED (2026-05-21):** Generic rubric renamed to §G prefix. All three rubrics now declare their prefix in a top-of-file comment. Cross-rubric references use fully-prefixed IDs. Convention documented in FRAMEWORK.md and enforced in rubric-edit-process.md validation checklist. Commit: f70b14b.
- The `BAD`/`GOOD` code blocks are optional (generic rubric §G3.1 doesn't have them). The copilot-review-loop's rubric cross-check (Step 7.5) only pattern-matches against BAD blocks — sections without BAD blocks are invisible to the cross-check.
- No machine-readable rubric index. Everything is inferred from markdown heading patterns.

**PRIORITY: HIGH** — the rubric is the core detection specification; ID collision or misparse breaks the loop.

---

## (a) INTERCONNECTION GRAPH

```
.preflight/config.json
  ├── read by → session-start hook → outputs session context string
  │                                    └── parsed by → every skill Step 0
  ├── read by → code-reviewer (rubric path, capture paths)
  ├── read by → copilot-review-loop (review.*, loop.*, capture.*, branch.*)
  ├── read by → fix-and-close (all fields)
  └── read by → migrate-service (migration.*, branch.*, test.*)

dependency-map.json
  ├── produced by → discovery-analyst
  ├── validated by → dependency-map-validator (lib/)
  │                   └── evidence written to → gate/map-validated
  ├── consumed by → fix-and-close (coupling grouping)
  │                  └── writes → active-groups.json
  │                                ├── enforced by → coupled-edit-gate
  │                                └── acknowledged by → write-group-ack
  └── checked for existence by → pre-push-gate

code-reviewer output (findings JSON)
  ├── consumed by → fix-and-close (groups findings, dispatches implementer)
  ├── consumed by → self-review (applies fixes directly)
  └── if CLEAN → triggers → write-gate-evidence(stage1-clean)
                              └── checked by → pre-push-gate

copilot-review-loop output (status + findings + stability)
  ├── consumed by → fix-and-close (routes by status code + stability)
  ├── writes → capture files (calibration-log, checklist-additions, false-positives)
  │             └── read by → code-reviewer (operative rules)
  └── writes → generation-spec-candidates.md

rubric files
  ├── read by → code-reviewer (detection walk)
  ├── read by → copilot-review-loop Step 7.5 (cross-check)
  └── calibrated by → capture files (severity override)
       └── managed by → copilot-review-loop (write) + batched rubric-edit PR (promote)
```

Key dependency chains:
1. **Config → everything** — config schema is foundational
2. **Rubric structure → code-reviewer output → fix-and-close grouping → active-groups → coupled-edit-gate** — the longest chain
3. **dependency-map.json → fix-and-close coupling → implementer brief** — the coupling analysis chain
4. **Capture file structure → code-reviewer operative rules → next service detection** — the self-improvement chain

---

## (b) PROPOSED ORDER FOR SPECIFICATION

Based on the interconnection graph (most foundational first):

1. **`.preflight/config.json` schema** — everything reads it
2. **Rubric file structure** — code-reviewer + copilot-review-loop + severity-matrix depend on it
3. **code-reviewer output format** — fix-and-close + self-review + migrate-service consume it
4. **copilot-review-loop output format** — fix-and-close consumes it; includes stability categories
5. **Capture file entry structures** (all 5 buckets) — copilot-review-loop writes, code-reviewer reads
6. **dependency-map.json schema** — discovery-analyst produces, validator + fix-and-close consume
7. **Gate evidence file format** — write-gate-evidence produces, pre-push-gate consumes
8. **Active groups file format** — write-active-groups produces, coupled-edit-gate + write-group-ack consume
9. **Implementer fix brief format** — fix-and-close produces, implementer consumes
10. **Session-start hook output format** — hook produces, all skills' Step 0 consume
11. **Metrics file schema** — fix-and-close produces, future consumers read
12. **Severity matrix** — code-reviewer consumes, capture files calibrate
13. **Oscillation detection state** — in-memory, consumed by copilot-review-loop and fix-and-close
14. **Generation-spec-candidates format** — copilot-review-loop writes, human consumes

---

## (c) DEPENDENCY-MAP-VALIDATOR EXISTING PATTERN

**What it does today** (`lib/dependency-map-validator.md`):

Three mechanical validation steps run as bash against the produced `dependency-map.json`:
1. **Independent files have no shared imports** — greps `using` statements in independent files and coupled files, checks intersection (lines 18-32)
2. **Coupled groups have verifiable call-chain edges** — checks at least one pair in each group has a direct type reference (lines 38-63)
3. **DI registration cross-check** — matches Program.cs AddScoped/AddTransient/AddSingleton registrations against coupling groups (lines 70-93)

Outcomes are WARNING (advisory) or HIGH-SEVERITY (must act):
- Step 1 warnings → move file to coupled group
- Step 2 warnings → keep group (conservative), log
- Step 3 warnings → MERGE files into same group immediately

**Could this pattern extend to other contracts?**

Yes. The pattern is: **"After an LLM produces structured output, run a mechanical (non-LLM) validation that catches structural errors the LLM commonly makes."**

Candidates for similar validators:
- **Config schema validator** — after user edits config, validate required fields for the declared mode
- **Code-reviewer output validator** — after Stage 1 returns, verify: JSON parses, severity values are from the allowed set, file paths exist on disk, line numbers are within file bounds
- **Active-groups validator** — after write-active-groups, verify: JSON parses, every file path exists, no file appears in multiple groups, groups contain ≥2 files (single-file "groups" are meaningless)
- **Capture entry validator** — after copilot-review-loop writes a capture entry, verify: `Survived:` is a number, section references match rubric section IDs, mandatory fields present

The pattern would be: `lib/<name>-validator.md` documents the checks; the orchestrator calls the bash validation immediately after the producer writes.

---

## (d) ANYTHING UNEXPECTED

1. **`lib/proactive-triggering.md`** — acts as a behavioral contract (not a state file or agent I/O) that specifies WHEN skills self-activate. It's a convention contract: the routing skill and proactive-triggering doc together define activation conditions. These are implicitly "consumed" by the main Claude session's decision-making but have no mechanical enforcement.

2. **`lib/skill-bootstrap.md`** — documents the Step 0 pattern that EVERY skill must implement. This is a cross-cutting structural contract: if a skill doesn't implement self-detection matching this spec, it breaks when the hook doesn't fire. Not a state file, not an I/O contract — it's an **implementation contract** (analogous to an interface in code).

3. **`lib/verification-discipline.md`** — a behavioral discipline contract. Not mechanically enforced (the gate system partially enforces it, but not completely). It defines the trust model between agents: "never trust a sub-agent's success report; verify independently."

4. **`skills/routing/SKILL.md`** — loaded by session-start hook into `additionalContext`. This is unique: it's a SKILL that acts as a BEHAVIORAL SPECIFICATION rather than an invocable command. It's never invoked by name; it's injected as context. Its "contract" is with the session-start hook (which loads it) and the main agent (which reads it from context).

5. **The `$CLAUDE_PLUGIN_ROOT` variable** — referenced throughout (generation-specs, defaults, hooks, lib) but never formally defined. It's an implicit contract between Claude Code's plugin loader and every skill/agent/hook. If the plugin root resolves differently on different machines, paths break.

6. **Oscillation detection state** (`lib/oscillation-detection.md:64-76`) — held in memory, not on disk. But the copilot-review-loop and fix-and-close both reference the same detection logic. If they disagree on the algorithm (cap at 3 vs 8, same-files vs same-line), one would STUCK when the other wouldn't. The `oscillation-detection.md` says Stage 2 cap is 8 (line 39) but `copilot-review-loop.md` says 3 (line 69) and `fix-and-close/SKILL.md` says 3 (line 46). **Active contradiction** between lib doc and agent definition.

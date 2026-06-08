---
name: bootstrap
description: Produces or validates a team's CLAUDE.md and supporting configuration through structured dialogue with the lead engineer. Three modes — Generate (fresh team), Validate (verify existing), Update (detect drift). The framework's adoption mechanism for any team on any stack.
argument-hint: "<mode: generate|validate|update> [--force to skip mode detection]"
allowed-tools: Read, Glob, Grep, Bash, Write, Edit, Agent
---

# /preflight:bootstrap — Team Configuration Generator

You are running bootstrap — the process that produces or maintains a team's CLAUDE.md and supporting preflight configuration. This is a conversation with the lead engineer, not a batch job. You analyze, you propose, you iterate, you commit only when alignment is explicit.

The user passed `$ARGUMENTS` as input. Parse:
- `generate` → Generate mode (fresh team, no CLAUDE.md)
- `validate` → Validate mode (verify existing CLAUDE.md against codebase)
- `update` → Update mode (detect changes since last bootstrap)
- No argument → auto-detect: if CLAUDE.md exists, suggest validate; if not, suggest generate.

## The Quality Contract

Bootstrap embodies expert practice. The quality bar is NOT "good starting point that improves through use." The quality bar is "matches expert practice on day one."

You are opinionated about format. You push back on patterns that violate learned practices. You refuse to produce mediocre output.

## CLAUDE.md Format Principles (Non-Negotiable)

These are the constraints your output must satisfy. They are not suggestions.

1. **Length: 200-300 lines.** Above 300 is failure. Instruction-following degrades as instruction count increases. If the team's content exceeds 300 lines, move content to pointer files.

2. **Structure: WHAT / WHY / HOW.** Every CLAUDE.md covers three axes:
   - WHAT: tech stack, project structure, code map
   - WHY: purpose of the project, major components
   - HOW: how the team works — test commands, build commands, verification steps

3. **Universal-only content.** Every instruction must apply to every kind of work. Task-specific content goes in pointer files (`docs/agent-context/`).

4. **No style rules.** Formatting, naming, import ordering belong in linters and formatters. Push back when a lead wants style rules in CLAUDE.md.

5. **Brief why-explanations.** Rules with one-line context propagate better than bare rules.

6. **Safe defaults over prohibitions.** "Use Y; X causes Z problems" beats "Don't use X."

7. **Progressive disclosure.** Pointer files for context that's only relevant to specific tasks. CLAUDE.md contains brief pointers with descriptions of when to read each file.

8. **Pointer-not-snippets.** Pointer files reference file:line, not code copies. Copies go stale; references stay current.

## Generate Mode

### Phase 1 — Codebase Analysis

Run the detector module first:
```bash
# Framework assets install under the consumer's .claude/ root. Resolve without
# CLAUDE_PLUGIN_ROOT (empty off-plugin / in sub-agents); git/pwd fallback resolves everywhere.
FRAMEWORK_ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}/.claude"
bash "${FRAMEWORK_ROOT}/lib/detector.sh"
```

If derived state exists at `.preflight/derived/state.json`, read it. Otherwise run the detector to produce it. If the detector fails or is unavailable, fall back to manual detection: identify the stack yourself from project files (.csproj, pom.xml, package.json, go.mod, Cargo.toml, requirements.txt/pyproject.toml), surface your finding, and proceed. Detector failure must not block bootstrap.

Then perform three-dimensional analysis:

**Architecture verification:**
- Map the project structure (directories, key files, entry points)
- Identify the tech stack, frameworks, libraries
- Identify build/test/deploy patterns from existing config
- Map service boundaries if multi-service

**Safety-relevant inspection:**
- Check git remotes — does origin point somewhere sensible?
- Check for credentials in unexpected locations
- Check for dangerous defaults in configuration
- Check for .env files, secrets in git history indicators

**Pattern recognition:**
- What development workflow does this team use? (branching, PR process, CI)
- What testing patterns exist? (unit, integration, e2e, coverage)
- What deployment target? (cloud provider, container, serverless)
- What observability? (logging, metrics, tracing)

Report findings to the user before asking questions.

### Phase 2 — Structured Questions

Ask questions in this order. Adapt based on what codebase analysis already revealed. Skip questions whose answers are already clear from analysis.

**Identity questions:**
- What is this project's purpose in one sentence?
- Who are the primary users of this codebase? (team size, roles)
- What's the team's experience level with AI-assisted development?

**Workflow questions:**
- What does your PR process look like? (reviewers, approval requirements)
- Are there branch naming conventions?
- What triggers deployment?

**Standards questions:**
- What quality bar does the team hold? (coverage targets, review standards)
- Are there patterns you always want followed? (architecture decisions, common mistakes to avoid)
- What should Claude never do in this codebase?

**Override questions (Layer 3 of config):**
- Surface any detected values where the team might deviate from auto-detection
- "I detected your test command as `dotnet test`. Is that correct, or do you use something different?"
- Capture overrides as natural-language statements for CLAUDE.md

**Behavioral Contract questions (only when `mode: migration`, or the team intends migration/refactor parity):**

The Behavioral Contract is the input the parity gate depends on. Bootstrap does NOT author it (a wrong auto-authored contract produces a false-green parity baseline — strictly worse than none). Bootstrap SCAFFOLDS it and the lead completes the behaviour list. Ask only what you need to scaffold:
- "Do you have a result-code / status convention callers key off? (e.g. `[EWS]\d{4}` codes, HTTP status enums, gRPC codes, a domain result object.)" — this seeds the recognition pattern. If the answer is unclear, leave it blank-with-guidance (do NOT guess a low-confidence regex — a blank forces authoring; a guess invites rubber-stamping).
- "Which is the LEGACY service/endpoint this team will migrate first?" — the contract describes what the **legacy code being migrated** does (always the OLD system's observable behaviour). Use the answer to point the comparison-surface candidates at the right files.

### Phase 3 — Draft Generation

Produce these artifacts:

1. **CLAUDE.md** — 200-300 lines, WHAT/WHY/HOW structure, universal content only
2. **docs/agent-context/** directory with pointer files:
   - `building.md` — build process details
   - `testing.md` — test patterns and coverage expectations
   - `architecture.md` — system design, service boundaries, key abstractions
   - Additional files based on team-specific needs (e.g., `migration-conventions.md`, `deployment.md`)
3. **.preflight/config.json** — project config with mode, rubric paths, capture paths, branch config
4. **Scan profile recommendation** — if a matching profile exists in `examples/scan-profiles/`, suggest configuring it. If not, offer to draft one based on the codebase analysis.
5. **Behavioral Contract scaffold (when `mode: migration`, or migration/refactor parity is intended)** — append the Behavioral Contract section to CLAUDE.md by stamping the template at `${FRAMEWORK_ROOT}/examples/behavioral-contract-template.md` (everything below its "WHAT BOOTSTRAP STAMPS" marker). This is the on-ramp that makes the parity gate START on the documented install→bootstrap path — without it, `spec-analyst` returns BLOCKED and parity is silently unavailable.

   <CRITICAL-INSTRUCTION>
   Bootstrap SCAFFOLDS the contract; it does NOT author the behaviour list. Fill ONLY the cheap, mechanically-derivable, human-eyeballable parts and LABEL them `AUTO-DERIVED — VERIFY`:
   - **Recognition pattern:** if codebase analysis found result-code-like literals (strings assigned to `*ResultCode`/`*Code`/`*Status` fields) that cluster into a clear regex, pre-fill it labelled `AUTO-DERIVED — VERIFY`. If you cannot derive one CONFIDENTLY, leave it BLANK with the `OPERATOR: COMPLETE` note — never emit a low-confidence guess (a guess invites rubber-stamping; a blank forces authoring). This is the (a) blank-not-guess rule.
   - **Comparison-surface candidate files:** pre-fill the detected entry-point / repository / model / auth-filter file paths labelled `AUTO`, each with an `OPERATOR: confirm` note (and the "confirm FULL transitive scope, not just the controller" warning the template carries).
   - **Behaviour list (result-code map, result-determination, side-effects/state, constraint handling):** leave ENTIRELY operator-authored. Do NOT pre-fill. A guessed behaviour list is a false parity baseline.
   - **Truth source:** the contract describes the **legacy code being migrated** (the OLD system's observable behaviour). Point the operator at the legacy source, not the new code.

   The stamped section keeps the headings spec-analyst requires verbatim ("recognition pattern", "Behavior categories", "Comparison surfaces"). Leave every `OPERATOR:` placeholder intact for the human — their presence is the DRAFT marker (see Validate mode). Note this may push CLAUDE.md beyond the 200-300 line target; the contract is load-bearing and exempt, but consider moving other content to pointer files to compensate.
   </CRITICAL-INSTRUCTION>

### Phase 4 — Iterative Alignment

Present the draft to the lead. Iterate:
- Surface anything you're uncertain about
- Push back on additions that violate format principles (too long, style rules, task-specific content)
- Explain why things go where they go (teach while generating)
- Accept corrections gracefully — the lead knows their team better than you do

**No commit without alignment.** Ask explicitly: "Are you happy with this? I'll commit all artifacts together."

### Phase 5 — Commit

When the lead approves:

**Write the approval sentinel BEFORE writing any protected files:**
```bash
mkdir -p .preflight/gate && echo "{\"approvedAtHEAD\":\"$(git rev-parse HEAD)\",\"approvedFiles\":[\"CLAUDE.md\",\".preflight/config.json\"],\"approvedAt\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" > .preflight/gate/bootstrap-write-approved
```
List exactly the files the lead approved in `approvedFiles`. The bootstrap-write-gate hook will block writes to existing CLAUDE.md or .preflight/config.json unless this sentinel is present and fresh.

Then:
- Write CLAUDE.md and .preflight/config.json (the gate will now allow it)
- Commit all artifacts together in one commit
- Message: `chore: bootstrap preflight configuration`
- Do NOT push — that's the lead's decision

**Clean up the sentinel after commit:**
```bash
rm -f .preflight/gate/bootstrap-write-approved
```
The sentinel auto-invalidates after the commit (HEAD moves), but explicit cleanup is belt-and-suspenders.

## Validate Mode

### Phase 1 — Independent Analysis

Read the existing CLAUDE.md. Then analyze the codebase INDEPENDENTLY — form your own conclusions before comparing.

Run the same three-dimensional analysis as Generate mode (architecture, safety, patterns).

### Phase 2 — Comparison

For each verifiable section of CLAUDE.md, classify:

| Verdict | Meaning |
|---|---|
| **Verified true** | Codebase evidence supports the claim |
| **Verified drift** | Codebase evidence contradicts the claim |
| **Cannot verify** | No evidence either way (often aspirational architecture) |

**Accuracy calculation:** verified-true sections / total verifiable sections. Aspirational content excluded from denominator.

**Behavioral Contract check (do this whenever a Behavioral Contract section exists, or `mode: migration`):**
- **Absent** — no "Behavioral Contract" section and `mode: migration`: report as a HIGH finding ("parity gate is unavailable — spec-analyst will return BLOCKED; run Generate mode or stamp the template at `${FRAMEWORK_ROOT}/examples/behavioral-contract-template.md`").
- **DRAFT** — section exists but still contains an unfilled scaffold placeholder. Detect placeholders PRECISELY: a placeholder is an HTML comment whose body begins with `OPERATOR:` or `AUTO-DERIVED` or `AUTO:` (i.e. matches `<!--\s*(OPERATOR:|AUTO-DERIVED|AUTO:)`), or a literal `TODO` token, occurring in the behaviour sections (result-code map, result-determination, side-effects, constraint handling). Do NOT match the bare word "OPERATOR" in explanatory prose — the scaffold's own warning blockquote and faithfulness-gate note legitimately mention "OPERATOR" in sentences; matching those would flag a fully-completed contract as DRAFT forever. Report DRAFT as — "the contract is a scaffold the operator has not yet completed; parity is NOT protecting this project until the placeholder sections are authored against the legacy source." This is the mechanical faithfulness interlock: a DRAFT contract is treated as not-yet-trustworthy, not as done.
- **Complete** — section exists, no scaffold-placeholder comments (`<!-- OPERATOR:/AUTO-DERIVED/AUTO: -->`) or `TODO` tokens remain, all three spec-analyst-required headings present (recognition pattern, Behavior categories, Comparison surfaces): report Complete. (Bootstrap does not attempt to verify the behaviour list's *faithfulness* to legacy — that is the human's ratification and the parity gate's job; bootstrap only verifies the scaffold was filled in.)

### Phase 3 — Format Assessment

Check CLAUDE.md against format principles:
- Line count (target 200-300, above 300 is failure)
- WHAT/WHY/HOW coverage
- Style rules present? (should be in linters)
- Task-specific content present? (should be in pointer files)
- Universal-only content?

### Phase 4 — Report

Present to the lead:
```
## Bootstrap Validate Report

**Accuracy: X% (Y/Z verifiable sections)**

### Verified True
- [section]: [evidence]

### Verified Drift  
- [section]: [expected vs actual]

### Cannot Verify (Aspirational)
- [section]: [why unverifiable]

### Format Assessment
- Length: X lines (target 200-300)
- Structure: [WHAT/WHY/HOW coverage]
- Issues: [style rules, task-specific content, etc.]

### Behavioral Contract
- Status: [Absent (HIGH if mode: migration) | DRAFT (OPERATOR sections unfilled — parity not protecting yet) | Complete]
- [if DRAFT: list which OPERATOR sections are still placeholders]

### Safety Findings
- [any dangerous configurations found regardless of CLAUDE.md coverage]
```

### Phase 5 — Iterate and Commit

If drift or format issues found, propose specific fixes. Iterate with lead. Commit revised CLAUDE.md when approved.

## Update Mode

### Phase 1 — Detect Changes

Compare current codebase state against derived state from last bootstrap (read `.preflight/derived/state.json` timestamp, compare git log since then).

Identify:
- New files/directories added
- Frameworks/dependencies added or removed
- Configuration changes
- New patterns emerging (new test patterns, new service boundaries)

### Phase 2 — Assess Impact on CLAUDE.md

For each change, determine:
- Does this invalidate anything in current CLAUDE.md?
- Does this require new content in CLAUDE.md?
- Does this require new/updated pointer files?

### Phase 3 — Propose Updates

Present proposed changes to the lead. Same iterative alignment as Generate mode.

Include format assessment — if CLAUDE.md has grown beyond 300 lines since last bootstrap, propose moving content to pointer files.

### Phase 4 — Commit

Same discipline as Generate mode — no commit without explicit alignment.

## Safety-Relevant Findings (All Modes)

Regardless of mode, ALWAYS surface these if found:
- Git remote pointing to unexpected repository (especially if origin → legacy/read-only repo)
- Credentials or secrets in unexpected locations
- Dangerous defaults in configuration files
- Missing .gitignore entries for sensitive files
- Force-push enabled on protected branches

These are surfaced prominently even if CLAUDE.md doesn't mention them. The codebase analysis is independent of CLAUDE.md coverage.

## What Bootstrap Does NOT Do

- Modify code — bootstrap produces configuration only
- Push — the lead decides when to push
- Merge — configuration PRs get normal review
- Override the lead — iterate and explain, don't argue past refusal
- Produce mediocre output — refuse to commit content that violates format principles
- Skip analysis — even in Generate mode, analysis runs before questions
- Hardcode stack assumptions — bootstrap works for any stack via the detector module

## Communication

Bootstrap is a conversation. The lead engineer is your partner in producing good configuration. Optimize for:
- Clear phase boundaries ("Phase 1 complete — here's what I found")
- Confidence annotations ("I'm confident about X, less sure about Y")
- Teaching moments ("This goes in a pointer file because...")
- Explicit checkpoints ("Ready to draft? Or do you have more context to share?")

## Edge Cases

- **Lead wants everything in CLAUDE.md:** Push back. Explain progressive disclosure. Offer to show examples of effective short CLAUDE.md files.
- **Codebase is empty/new:** Generate minimal CLAUDE.md focused on project purpose and initial conventions. Most pointer files will be created as the project grows.
- **Lead disagrees with a format principle:** Explain the reasoning. If they still disagree after explanation, note it as an override and document why in the CLAUDE.md itself.
- **Multiple stacks in one repo (monorepo):** Produce one root CLAUDE.md with pointers to per-stack context files.
- **Existing .preflight/config.json:** In Generate mode, merge with existing config rather than overwriting. Surface conflicts.

Begin now. Detect mode from `$ARGUMENTS`, run codebase analysis, and start the conversation.

---
name: behavior-spec
description: "Extract a behavioral specification from a service's source code. Produces behavior-spec.json with citation-grounded behaviors and completeness check."
argument-hint: <ServiceName> [--legacy|--migrated]
allowed-tools: Read, Glob, Grep, Bash, Agent
---

# /preflight:behavior-spec — Behavioral Extraction

You are running a behavioral extraction against a service. This produces a `behavior-spec.json` that the parity gate uses to detect behavioral drift between legacy and migrated implementations.

The user passed `$ARGUMENTS` as input. Parse:
- Service name (required)
- `--legacy` flag: extract from the legacy repo path (configured in `.preflight/config.json` under `migration.legacyRepoPath`)
- `--migrated` flag: extract from the migrated service in this repo (default if no flag)
- If neither flag is given, default to `--migrated`

## Step 0 — Environment Detection

1. Search for config: `.preflight/config.json` > `.cpsl/config.json` > `.forge.json`
2. If found: extract `migration.legacyRepoPath`, `migration.servicesRoot`, service paths.
3. Confirm `CLAUDE.md` exists at project root and contains a "Behavioral Contract" section.
4. If CLAUDE.md has no Behavioral Contract section, inform user and stop.

## Step 1 — Ensure Dependency Map

The spec-analyst requires either a dependency map or an explicit file list.

**For `--migrated` (default):**
- Check for `<service-folder>/dependency-map.json`.
- If missing: invoke discovery-analyst (via Agent tool, `subagent_type: discovery-analyst`) with brief "dependency-map-only refresh" against the migrated service folder. Wait for DONE.

**For `--legacy`:**
- A dependency map typically does not exist for legacy code. Instead, determine the file list from the comparison surfaces declared in CLAUDE.md's Behavioral Contract. Map each surface to its legacy file location using the hints in CLAUDE.md (e.g., "legacy: CPSLTokenRepository" for the business logic surface).
- Present the resolved file list to the user for confirmation before proceeding.

## Step 2 — Dispatch spec-analyst

Use the Agent tool with `subagent_type: spec-analyst`. Include in the prompt:
- Service name
- Source path (legacy repo path or migrated service folder)
- Dependency map path OR explicit file list
- Target repo root (this project's root — where CLAUDE.md lives and where `.preflight/<service>/behavior-spec.json` will be written)

## Step 3 — Report Result

Read the spec-analyst's response. Surface to the user:
- **DONE**: report behavior count, category breakdown, completeness PASS. Note the output path.
- **DONE_INCOMPLETE**: report the missing entries. Ask user if they want to investigate or accept as-is.
- **BLOCKED**: surface the reason and suggestion. Do not retry automatically.
- **ERROR**: surface verbatim.

## What This Does NOT Do

- Edit source code
- Run Stage 1 review
- Open PRs or push
- Invoke the fix-and-close pipeline
- Modify the dependency map (that's discovery-analyst's job)

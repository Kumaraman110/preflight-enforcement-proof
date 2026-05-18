# Project Detection Logic

This document is reference material for agents and skills. It describes how to detect the project type at runtime.

## Config File Search Order

Look for these files in the current working directory (first match wins):

1. `.preflight/config.json`
2. `.cpsl/config.json`
3. `.forge.json`

## Config Schema

```json
{
  "mode": "migration" | "api-new" | "generic",
  "rubric": "path/to/rubric.md",
  "capture": {
    "calibrationLog": "path/to/calibration-log.md",
    "checklistAdditions": "path/to/checklist-additions.md",
    "falsePositives": "path/to/false-positives.md"
  },
  "review": {
    "copilotReviewerLogin": "copilot-pull-request-reviewer[bot]",
    "pollIntervalSeconds": 200,
    "initialWaitSeconds": 90
  },
  "loop": {
    "rubricEditCadence": 5,
    "maxStage1Iterations": 5,
    "maxStage2Iterations": 3,
    "maxRubricTokens": 20000,
    "maxCaptureTokens": 5000,
    "oscillation": {
      "stopOnSameFilesAcrossConsecutiveIterations": true,
      "stopOnSameLineModifiedConsecutively": 3
    }
  },
  "branch": {
    "base": "main",
    "remote": "origin"
  },
  "test": {
    "command": "dotnet test",
    "coverageBaseline": 96.1
  },
  "migration": {
    "legacyRepoPath": "/path/to/legacy/repo",
    "servicesRoot": "src",
    "referenceService": "path/to/reference/service"
  }
}
```

## Fallback Behavior (No Config)

When no config file exists:
- Mode: `generic`
- Rubric: `${CLAUDE_PLUGIN_ROOT}/defaults/rubric-generic.md`
- Branch base: `main`
- Branch remote: `origin`
- Test command: auto-detect (if `.csproj`/`.sln` exists → `dotnet test`; if `package.json` → `npm test`; otherwise skip)
- Capture files: `docs/review/{calibration-log,checklist-additions,false-positives}.md`
- No migration-specific features activate

## Mode Implications

| Mode | Rubric | Skills Available | Extra Context |
|---|---|---|---|
| `generic` | Default generic | self-review, fix-and-close, TDD, debugging | None |
| `migration` | Project rubric + default migration | All generic + migrate-service | Legacy repo path required |
| `api-new` | Project rubric + default API design | All generic + scaffold-api | Reference service optional |

## CLAUDE.md Integration

If the project has a `CLAUDE.md` at root, it is treated as supplementary guidance for all agents. The rubric is the formal detection spec; CLAUDE.md provides architectural context and team conventions.

Priority: rubric rules > CLAUDE.md guidance > agent defaults.

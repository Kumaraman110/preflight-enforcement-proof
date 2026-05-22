# Reference Examples

These files are reference examples, not framework defaults. The framework never auto-loads anything from this directory.

## What is here

- `rubrics/` — Example rubric files showing what team rubrics look like in practice
- `generation-specs/` — Example generation specs showing the paste-don't-reconstruct format
- `scan-profiles/` — Example scan profiles for the analyst sub-agent (created in PR 4)

## How to use these

Look at these to understand the format. Then write your own team-specific versions through the bootstrap generator (`/preflight:bootstrap`) or by hand. Your team's content lives in `.preflight/` in your own repo, not here.

The framework's commitment is that no opinionated content ships as defaults. Examples exist for inspiration. Defaults do not exist.

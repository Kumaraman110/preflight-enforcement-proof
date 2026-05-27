# Scan Profiles — Format Specification

This directory contains example scan profiles that ship with preflight. Each profile defines technical-debt patterns for a specific technology stack. Teams adopting preflight either use one of these examples directly, copy and modify one, or author their own profile from scratch.

This README is the format specification. Read it before authoring a new profile.

## Where Profiles Live

Profiles are discovered in this order (first match wins):

1. Path specified in `.preflight/config.json` under the `scanProfile` field (e.g., `"scanProfile": "docs/our-profile.md"`)
2. `.preflight/scan-profiles/<stack>.md` in the project directory (where `<stack>` matches auto-detected stack)
3. `${CLAUDE_PLUGIN_ROOT}/examples/scan-profiles/<stack>.md` (the example profiles in this directory)
4. Built-in minimal scan (hardcoded secrets only) — used when no profile resolves

The `<stack>` is detected from project files: `.csproj`/`.fsproj`/`.vbproj` → dotnet, `pom.xml` → java, `requirements.txt`/`pyproject.toml` → python, `package.json` → node. When multiple stack indicators exist, the one closest to the working directory wins.

## File Structure

A scan profile is a markdown file with YAML frontmatter followed by category sections.

### Frontmatter

Required fields:

```yaml
---
name: <machine-readable-identifier>
description: <one-line human description>
stack: <stack-name>
version: 1
---
```

- `name`: Used in logs and status output. Lowercase, hyphenated. E.g., `dotnet-framework`, `java-ee`.
- `description`: One-line summary. Shown when the profile is loaded.
- `stack`: One of `dotnet`, `java`, `python`, `node`, `go`, `rust`, or a custom name.
- `version`: Currently always `1`. Future format changes will increment this; existing profiles continue to work because the analyst maintains backward-compatible parsing.

### Category Sections

Each category is a markdown section with this exact structure:

```
## §<ID> <Category Name>

**What:** <one-sentence description of the pattern>
**Why:** <one-sentence reason this matters for migration/modernization>
**Severity:** <informational | recommended | required>
**Glob:** <comma-separated file patterns to search>
**Signal:** <detection approach — see below>
**Replacement:** <brief guidance on the modern alternative>
```

Field semantics:

- **§\<ID\>**: Unique identifier within the profile. Use a single-letter prefix matching the profile (e.g., `§D1`-`§D7` for dotnet, `§J1`-`§J9` for java).
- **What**: Concrete pattern description. Avoid jargon when possible.
- **Why**: Calibrates severity in ambiguous cases. Explains the engineering cost of leaving this pattern in place.
- **Severity**: Three levels.
  - `informational`: Note in report, no score impact. Migration can proceed without addressing.
  - `recommended`: Lowers readiness score. Should be addressed during or after migration.
  - `required`: Must be resolved before migration can proceed.
- **Glob**: File patterns. Comma-separated. E.g., `*.cs, *.csproj` or `*.java, pom.xml`.
- **Signal**: How the analyst detects this pattern. Dual-mode (see below).
- **Replacement**: One-paragraph guidance on the modern alternative. Helps the engineer know what to do, not just what's wrong.

### Signal Field: Dual-Mode Detection

The Signal field supports two modes.

**Regex mode (backtick-enclosed):** The pattern inside backticks is used as a regex for grep/ripgrep search. Preferred when patterns are mechanical and unambiguous.

Example:
```
**Signal:** `unity\.RegisterType|unity\.RegisterInstance|container\.Resolve<|IUnityContainer`
```

**Natural-language mode (plain text, no backticks):** The analyst reads the source code and uses LLM judgment to identify instances. This is not a mechanical regex search; the analyst relies on its understanding of the pattern described. Preferred when patterns require contextual understanding.

Example:
```
**Signal:** Methods that perform synchronous I/O (database queries, HTTP calls, file reads) inside an async context or on a request-handling thread without awaiting.
```

Regex mode is preferred when possible — it's deterministic, verifiable, and produces consistent results. Natural-language mode is for patterns that resist mechanical detection.

## Conventions

- **Profile size:** Typically 5-15 categories. Fewer than 5 is shallow; more than 15 overwhelms the report.
- **Category order:** Order by detection priority (most important to find first).
- **ID prefix:** Use a single-letter prefix unique to the profile (`D` for dotnet, `J` for java, `P` for python, etc.). This enables unambiguous cross-profile reference.
- **Modification:** Teams freely add, remove, or modify categories after copying an example profile. The framework imposes no fixed category set.
- **Frontmatter required:** All four frontmatter fields (`name`, `description`, `stack`, `version`) are required. Missing frontmatter causes profile-loading failure and fallback to minimal scan.

## Versioning Contract

The `version` field future-proofs the format against breaking changes:

- Current version: `1`
- Future versions: When the format changes (new required fields, restructured layout), the new version increments. The analyst always supports the current version plus best-effort parsing of newer versions (degrading gracefully on unrecognized fields).
- Backward compatibility: Existing profiles with `version: 1` will continue to work indefinitely. The framework does not force upgrades.

## Example Category (fully annotated)

```
## §D1 Legacy DI Container (Unity)

**What:** Unity container registrations (RegisterType, RegisterInstance, Resolve<T>) indicating legacy DI that must be replaced.
**Why:** .NET 10 uses Microsoft.Extensions.DependencyInjection natively. Unity is unmaintained and incompatible with modern .NET.
**Severity:** required
**Glob:** *.cs
**Signal:** `unity\.RegisterType|unity\.RegisterInstance|container\.Resolve<|IUnityContainer|UnityContainer`
**Replacement:** Constructor injection via Microsoft.Extensions.DependencyInjection. Register dependencies in Program.cs using builder.Services.AddTransient<T>(), AddScoped<T>(), or AddSingleton<T>() based on lifetime. Replace container.Resolve<T>() calls with constructor parameters.
```

This example demonstrates all six fields, shows regex-mode Signal, and provides actionable Replacement guidance.

## How To Author a New Profile

1. Copy the closest existing example as your starting point.
2. Update frontmatter (name, description, stack).
3. For each technical debt category your team cares about, add a §-section with all six fields.
4. Use regex-mode Signal when patterns are mechanical. Use natural-language Signal when judgment is required.
5. Validate by placing the profile at `.preflight/scan-profiles/<stack>.md` and running discovery-analyst. The analyst will warn if the file is malformed.
6. Iterate. As your team encounters edge cases during migration, refine the categories.

# The Preflight Mature Framework — Design Document

**Status:** Sections 1-4 locked. Sections 5+ pending after refactor execution.
**Last update:** May 21, 2026
**Authorship:** Collaborative — Kumar Aman with CTO-mode AI

---

## Section 1 — What preflight is

Preflight is a bet on a specific thesis about where AI-assisted engineering is heading, and a specific architecture for solving the problem that thesis identifies.

### The thesis

The model is no longer the bottleneck. Trust is.

For years, the conversation about AI-assisted engineering was about whether the model could do the work at all. Could it write code that compiled? Could it understand context? Could it not hallucinate APIs? Those questions are mostly answered. Modern models can do the work. The question has shifted, and most of the field hasn't caught up to the shift.

The new bottleneck is whether the model's work can be trusted enough to ship. Trusted by the engineer using it. Trusted by their team. Trusted by their reviewers. Trusted by the people who have to maintain the code six months later. Trusted by the regulators who audit the development process. Trust isn't a model property. Trust is a systems property — it lives in the verification mechanisms around the model's work, not in the model itself.

The next decade of AI-assisted engineering will be won by whoever solves trust, not whoever has the best model.

### What follows from this

Three things are load-bearing once you accept the trust thesis.

**Verification cannot be a model job.** If you trust the model's work by asking the model to verify itself, you have created a circular dependency. The model that's brilliant can also be inconsistent, and you cannot tell the difference from inside the model. Real verification has to live outside model judgment — in mechanical systems, in deterministic checks, in evidence files that exist regardless of whether the model is having a good session or a bad one. Most current approaches to AI-assisted engineering try to make the model smarter, more careful, better-prompted. Those help at the margin but do not solve the trust problem. You solve trust by building infrastructure the model cannot bypass, not by hoping the model behaves.

**Standards must live where they survive.** A team's quality bar lives in someone's head, or in a style guide nobody reads, or in tribal knowledge that decays. When you put that bar in a prompt, it lasts one session. When you put it in a PR template, it lasts until people stop reading PR templates. When you put it in a framework that reads it automatically and enforces it mechanically, it lasts as long as the framework runs. The standards-as-living-files commitment is what makes AI-assisted work durable across engineers and time. Without it, every team using AI is rebuilding their quality discipline from scratch every time someone joins or leaves.

**Frameworks must learn or they decay.** Static rule sets age. The codebase evolves, the team's understanding evolves, the patterns that matter shift. A framework that ships with rules and stops there becomes less useful every quarter. The frameworks that survive are the ones that get smarter with use — the ones where the act of using them generates the next version of the rules. Self-improvement is not a feature. It's a structural requirement. No author can possibly anticipate every pattern every team will encounter, so the framework has to generate its own next version through accumulated usage.

### Why now

Three trends are converging that make this the moment.

Models crossed the capability threshold. Three years ago, asking the model to do real engineering work was experimental. Today, modern models can carry out substantive engineering tasks when given good context. The question is no longer "can it do the work" but "can we trust the work it does." That trust problem is now front-and-center for everyone using AI in production engineering contexts.

Enterprise adoption is starting and stumbling. Companies are pushing AI into their engineering workflows. They are discovering that an engineer using AI is faster but less consistent. They need defensibility — audit trails, quality assurance, standards enforcement — and most current tooling does not provide it. There is a real, unmet demand for trust infrastructure.

The tooling stack is mature enough to build on. Claude Code, Cursor, GitHub Copilot, MCP — the substrate for building frameworks like this exists now. Five years ago you would be inventing the runtime. Today you can build the framework on top of capable AI tooling and focus on the trust problem itself.

This window — where the model is capable enough, the adoption is real enough, and the tooling supports building on top — is when frameworks like preflight get built.

### The bet preflight makes

The thesis is general. Many people could try to build something against it. Preflight makes four specific architectural commitments that together are the bet.

**Discipline scaffolding at the framework level.** Not a linter — too shallow. Not a model wrapper — still depends on model judgment. Not a code review tool — catches things too late. The right shape is a framework that scaffolds the entire engineering workflow with mechanical enforcement at every gate and a learning loop that compounds across uses.

**Mechanical enforcement as the verification primitive.** Hooks that fire on tool events. Gates that check evidence files. Hard caps the model cannot extend. These primitives can be argued with by no one. The model can be brilliant or distracted; the gate fires the same. This is the unglamorous work that most competitors will try to skip. Skipping it is why their frameworks will not survive contact with production.

**Self-improvement as the centerpiece, not a feature.** Every external catch becomes a candidate for local catch next time. Findings are classified, accumulated, and promoted into the team's operative rules through a human-reviewed PR process. The framework reviewing tomorrow's work knows more than the framework that reviewed yesterday's. The architectural commitment is concrete: every issue caught by external review on work N should be caught by local review on work N+1. Learning is mechanical, not aspirational.

**Stack-neutrality at the core, with reference implementations.** Frameworks that bake in one stack become tools for that stack and never escape it. Frameworks that try to be everything to everyone never get specific enough to be useful. Preflight's design is a stack-neutral core that adapts to any team's stack via context the framework reads from CLAUDE.md, plus optional adapter content for specific stacks. The path lets the framework prove itself in one stack (currently .NET) and then genuinely generalize without rewriting.

These four commitments differentiate preflight from anything else trying to solve this problem.

### How the bet shows up in practice

A team adopts preflight by pointing it at their codebase. The team's lead engineer runs a one-time generator that produces a CLAUDE.md describing the team's stack, conventions, and standards. The generator asks questions, analyzes the codebase, and iterates with the lead until the CLAUDE.md is right. From that point forward, the framework reads from CLAUDE.md to inform everything it does.

When any engineer on the team uses Claude Code for engineering work, preflight activates automatically. Its skills (review, fix, scaffold, debug, decide, and a small set of others) provide the scaffolding for whatever work is happening. Sub-agents handle specialized roles with strict boundaries — read-only reviewers do not edit, fresh-context implementers do not review, learning agents do not push. Hooks fire on tool events to enforce mechanical gates — work cannot be pushed before tests pass, before review is clean, before coupled files are acknowledged.

When external review (typically GitHub Copilot, or another engineer in PR review) catches something preflight missed, the catch becomes input to the learning loop. Findings are classified — was the framework's rule wrong, missing, or correctly applied? Each classification routes to a different outcome. Findings that surface as new patterns accumulate. When evidence builds up across multiple uses, a batched rubric-edit PR proposes promoting the patterns into operative rules. A human reviews and merges. The next run of the framework knows more.

Over time, the team's rubric grows. The framework that reviews this team's work in month six is qualitatively better than the framework that reviewed their work in month one — not because the team maintained it, but because the framework's structural commitment to learning produced the improvement automatically.

### Who preflight is for

Preflight is for anyone using Claude Code or equivalent AI assistance who wants their AI-assisted work to meet a consistent standard without depending on every prompt being perfect.

For teams, preflight earns its place quickly. Multiple engineers contributing, consistency that matters, defensibility, regulated contexts, production systems — these are the conditions where mechanical enforcement and accumulated learning produce visible improvements over time. Team adoption is where preflight's federation contract matters most, because multi-engineer parallel work is what motivated that design.

For solo engineers, preflight is still useful. The discipline scaffold helps work stay consistent across sessions. The mechanical gates catch the things you forget to check when you are tired. The learning loop means your own framework gets better as you use it. Six months from now, when you come back to a project, the framework remembers what mattered.

For larger organizations, preflight provides auditability. AI-assisted engineering work becomes defensible because there is a clear record of what standards were checked, what was caught, what was learned. The kind of thing that matters when "we used AI" needs to be justified to a regulator, an enterprise customer, or an internal review board.

The framework scales down to one engineer and scales up to a team of dozens.

### What preflight is not

Preflight is not a code generator. It constrains how code gets written but does not write it.

Preflight is not a GitHub PR review tool. It catches things before the PR reaches a human reviewer, so the PR is already clean by the time a human looks at it.

Preflight is not a replacement for engineering judgment. Anything requiring real judgment stays with the engineer. The framework handles the mechanical parts.

Preflight is not stack-specific. The framework's core is stack-agnostic by design. It adapts to whatever stack the team works in via CLAUDE.md extraction. Reference implementations exist for specific stacks (currently .NET), but these are examples of how to use the framework, not the framework itself.

Preflight is not a static rule set. The rules evolve through the self-improvement loop.

### What success looks like

Preflight succeeds when a new engineer joining a team produces work that meets the team's standard from day one, because the framework is enforcing the standard rather than expecting the engineer to know it.

Preflight succeeds when the same engineer's work does not drift in quality across sessions, because the framework holds the standard steady regardless of how tired or distracted the engineer is.

Preflight succeeds when a team's framework knows more after a month than it knew when first adopted, because the learning loop is doing its job. Each external catch becomes a local catch.

Preflight succeeds when AI-assisted engineering work becomes auditable.

Preflight succeeds at the field level when the patterns it pioneered become the standard way teams think about AI-assisted engineering reliability.

The bet succeeds when "how do you trust AI-generated code" stops being an open question, and the answer involves preflight or frameworks built on what preflight pioneered.

### Current status

Preflight is at v0.1-pre. The core architecture is designed and being implemented. First real-world usage begins shortly with the framework's author on .NET work, expanding to two additional team members in the following weeks, then to engineers working in other stacks (Java, Python, React) within the following month. The framework is currently closed-source and personally maintained.

The strategic intent is to prove the patterns through proven use across teams and stacks, with paths forward including commercialization, acquisition, or eventual open-sourcing if neither commercial path materializes.

The self-improvement loop is designed and documented but has not yet run on real captured findings. The first batched rubric-edit PR is ahead, not behind. Multi-stack validation is pending — the framework's core is stack-neutral, but the existing reference implementation targets .NET, and demonstrating that the framework genuinely generalizes requires running it against a non-.NET project with a custom rubric.

The framework is genuine. The patterns are real. The proof that the patterns generalize and that the learning loop produces measurable improvement is the work ahead — and it begins immediately.

---

## Section 2 — Framework Architecture

### How the framework is built

Preflight is one product, built on Claude Code as its runtime. It is not a library, not a set of optional pieces, not a multi-runtime tool. A team installs preflight and gets the whole framework. Everything below describes the parts of that whole, not separable products.

The architecture follows from the strategic commitments in Section 1. Mechanical enforcement requires hooks. Role separation requires sub-agents. User invocation requires skills. Team adaptation requires reading context from CLAUDE.md. Self-improvement requires captured findings flowing into operative rules. The architecture is what makes those commitments actually work in practice.

### The three-part picture

At the highest level, preflight has three parts.

**Part one — the framework itself.** Stack-agnostic. Workflow-agnostic. Does not know what language you are working in, does not know what kind of work you are doing, does not know which team you are. Contains the discipline patterns, the role-separated capabilities, the mechanical enforcement, the learning loop. This is what gets installed when a team adopts preflight.

**Part two — the team connection.** When a team installs preflight, the framework reads context from CLAUDE.md — the same file Claude Code already loads at session start. The team's stack, conventions, architectural rules, what they care about — all of this informs how the framework operates. The framework adapts to the team, not the team to the framework.

**Part three — the team's project content.** The team's specific rubric, generation specs, config, and accumulated captures. This content is produced through the bootstrap generator on first installation, then evolves through use. It lives in the team's repo, version-controlled with their code, owned by the team. The framework reads it but does not ship it.

The boundary between part one and parts two/three is the boundary between what is framework and what is team. The framework's commitment is that part one stays stack-agnostic and the team's content carries everything stack-specific.

### The six primitives

Preflight is built from six architectural primitives. Every component of the framework is one of these. Nothing in the framework exists outside this set.

**Primitive one — skills.** Skills are how engineers invoke work through the framework. They are the user's entry points. When an engineer types /preflight:name in Claude Code, a skill activates and orchestrates the work that follows. The framework ships eight skills — a small, deliberate set covering the workflows the framework supports. Each skill represents a shape of work, not a kind of code. The skill provides the scaffolding; the actual stack-specific intelligence comes from the team's CLAUDE.md context.

**Primitive two — sub-agents.** Sub-agents handle specialized work with isolated context and strict role boundaries. Each sub-agent is a separate Claude Code agent dispatched by the main session through the Agent tool. The framework has four sub-agents: reviewer, analyst, implementer, external-review handler. Each enforces role separation that genuinely matters — read-only reviewers cannot edit, fresh-context implementers cannot review, learning agents cannot push.

**Primitive three — hooks.** Hooks are the mechanical enforcement layer. Bash scripts that fire on Claude Code lifecycle events. They cannot be bypassed by the model. The framework has six hooks: session-start, pre-push gate, coupled-edit gate, evidence writers, group writers, drift detector. The simplicity is the point — they are predictable, debuggable, and impossible to argue with.

**Primitive four — the discipline core.** Some concepts are referenced across the framework — verification discipline, mechanical gates, classification rules, severity matrix, role boundaries, the federation contract. In the mature framework, these are inlined into skills and sub-agents at activation through the session-start hook. Every skill the user invokes runs with the discipline core present in context. This is a structural change from referencing lib/ documents — the discipline core is always present, not contingent on the model choosing to read it.

**Primitive five — the bootstrap generator.** The bootstrap generator is a first-class capability, not an afterthought. It is the mechanism by which a team adopts preflight. The lead engineer runs /preflight:bootstrap once. The generator asks structured questions, analyzes the codebase, iterates with the lead, and produces the team's CLAUDE.md, initial rubric, generation specs, and configuration. Without bootstrap, adoption requires the team to author content from scratch — which is high friction and prone to producing low-quality content. The bootstrap generator eliminates that friction by producing high-quality team content through structured conversation.

**Primitive six — templates and reference examples.** The framework does not ship opinionated default content. The framework ships empty templates (rubric structure with no rules, config structure with null values, generation spec format with no patterns) and reference examples (concrete examples of what one team's content looks like, clearly labeled). The bootstrap generator may show examples during the conversation to help the team understand format, but never copies examples into team content. Examples exist for inspiration, not consumption. The framework's defaults are zero content — bootstrap produces team-specific content from scratch.

### The eight skills, four sub-agents, six hooks

Detail on each is in Section 4. The lists here are for architectural completeness.

**Skills:** bootstrap, review, fix-and-close, scaffold, migrate, rubric-edit, gps-decide, routing.

**Sub-agents:** reviewer, analyst, implementer, external-review handler.

**Hooks:** session-start, pre-push gate, coupled-edit gate, evidence writers, group writers, drift detector.

### How the parts compose

When a team installs preflight, the framework (part one) is installed as a Claude Code plugin. The lead engineer runs /preflight:bootstrap, which produces team content (part three) — CLAUDE.md, rubric, generation specs, derived state. The framework now has the team connection (part two). Engineers begin using preflight on real work. Periodically, /preflight:rubric-edit promotes accumulated captures into the team's operative rubric.

Every interaction goes through this pattern. The framework's contract with the team is: give me CLAUDE.md and your content, and I will operate on your work consistently. The team's contract with the framework is: maintain CLAUDE.md and your content accurately, and run rubric-edit periodically. The contract is small enough to be reliable.

### What is deliberately not in this architecture

**No adapter ecosystem.** The framework is one product, not a core plus plugins. Stack-specific content lives in team content, not in adapter packages.

**No multi-runtime support.** The framework is built on Claude Code. Cursor and other tools are not in scope.

**No model-specific knowledge.** The framework works with whatever model Claude Code is configured to use.

**No team-shared captures across organizations.** Captures live in each team's repo. The framework does not call home.

**No automatic rubric updates from external rule databases.** The team owns their standards.

**No default rubrics or generation specs.** The framework ships empty templates and reference examples but never opinionated defaults. Current defaults/ content moves to examples/ directory as labeled reference material.

These exclusions are deliberate.

### How the framework treats existing code

A philosophical commitment with architectural teeth.

**Existing code is the result of decisions, not the absence of decisions. The framework's default posture toward existing code is respect, not correction.**

Every line of legacy code was put there by an engineer who had context the framework cannot see from the code alone. The framework does not assume the existing implementation is wrong. It assumes the existing implementation reflects choices the framework cannot fully see. The framework's job is to recover the context, surface it as a decision point, and let the engineer choose.

This is the inverse of how most modernization tools work. Most tools detect anti-patterns and apply transformations mechanically. Preflight detects patterns that look like anti-patterns by modern standards and treats them as questions to investigate, not problems to fix.

The analyst sub-agent during migration discovery is required to investigate legacy intent for any pattern flagged as suboptimal. The framework presents tradeoff decisions to the engineer, not transformation results. When the engineer faces a non-trivial tradeoff, GPS activates. Every decision and its reasoning is recorded in the audit trail.

The framework refuses to be the entity that knows better than the legacy code. It is the entity that asks better questions about it.

### What this architecture requires to actually work

For this architecture to work in practice, three things have to hold.

**Bootstrap quality.** The bootstrap generator has to produce good CLAUDE.md, good rubric, good generation specs. If bootstrap is bad, the team's content is bad, and everything downstream is degraded.

**Discipline core inlining.** Skills and sub-agents have to actually carry the discipline core in their activation context, not reference it informally. If skills slip back to informal references, the discipline becomes contingent on model behavior.

**Hook reliability.** The mechanical enforcement only works if hooks actually fire and actually enforce. The hooks need to be maintained with the seriousness their load-bearing role deserves.

These three requirements are the framework's real implementation risk.

---

## Section 3 — Configuration and the Team Connection

### The connection contract

Preflight's connection to a team is asymmetric but bounded. The framework gives the team a complete operational scaffold. The team gives the framework one thing: truthful context about their work, maintained over time.

The contract is small enough to be reliable. The team's obligation is to maintain CLAUDE.md as an honest description of their codebase, and to author and evolve their rubric, generation specs, and config as their work evolves. That is it. No proprietary configuration language. No framework-specific files that duplicate what the team already maintains for Claude Code.

### What the team owns

**CLAUDE.md** at the repo root. Describes the codebase in plain English.

**.preflight/rubric/** directory containing the team's rubric files.

**.preflight/generation-specs/** directory containing the team's generation specs for scaffolding work.

**.preflight/captures/** directory holding capture files for accumulated findings.

**.preflight/archive/** directory holding archived captures (promoted, consumed, deferred).

The team's content is all under .preflight/ and CLAUDE.md. Everything is version-controlled with the team's code. Everything is human-readable.

### What the framework owns

The skills, sub-agents, and hooks. The discipline core (inlined at activation). Templates (empty starting points). Reference examples (clearly labeled, never loaded as defaults). The bootstrap generator skill.

Framework files live in the plugin installation location, separate from any team's repository.

### CLAUDE.md as the team's bible

CLAUDE.md is the load-bearing file for the team connection. Everything the framework does on the team's work flows through CLAUDE.md content.

The framework extracts from CLAUDE.md by asking the model. Not by parsing structured fields. CLAUDE.md remains a natural-language document the team maintains for human readers, and the framework treats it as authoritative prose to be interpreted by the model as needed.

The model-based extraction has real risks. The framework's response is verification at the moments that matter and bootstrap-time alignment to ensure CLAUDE.md is good enough to extract from reliably.

### The bootstrap generator: three modes, one ritual

The bootstrap generator is the only mechanism that touches CLAUDE.md. The framework treats CLAUDE.md as content that changes through discipline, not through direct editing.

**Generate mode — fresh team, no existing CLAUDE.md.** The lead engineer runs /preflight:bootstrap. The generator analyzes the codebase, asks structured questions, drafts CLAUDE.md and initial team content, iterates with the lead, commits when alignment is explicit.

**Validate mode — team has existing CLAUDE.md.** The generator reads existing CLAUDE.md, analyzes the codebase independently, compares against codebase reality, produces an accuracy assessment with explicit percentage.

The percentage represents sections of CLAUDE.md that the framework verified against codebase reality divided by total verifiable sections, excluding sections that could not be verified either way. A section holds true if the framework finds supporting evidence. A section needs revision if the framework finds contradicting evidence.

Surfaces sections that hold true, sections needing revision, sections missing from CLAUDE.md, and framework-specific information needed. Iterates with the lead. Commits revised CLAUDE.md when approved.

**Update mode — detect changes since last bootstrap.** Reads current CLAUDE.md, analyzes current codebase, compares against codebase state at the previous bootstrap, identifies what has changed, surfaces drift, iterates with lead, commits when approved.

**The discipline behind three modes.** All three modes share the commitment: CLAUDE.md changes only through bootstrap, never through direct editing. The framework cannot prevent direct edits but treats them as discipline violations and surfaces warnings: "CLAUDE.md was modified outside of bootstrap in commit X. Consider running /preflight:bootstrap in validate mode to verify current accuracy."

This parallels rubric discipline — rubric only evolves through /preflight:rubric-edit PRs.

### Configuration: zero authoring, full verification

Teams author zero structured configuration files. The framework derives operational values from the team's existing repo artifacts, verifies the derivations rigorously, and accepts overrides through natural-language in CLAUDE.md.

**Layer one: the detector module.** A framework component that inspects the team's repository and infers operational values from existing artifacts — package.json, .csproj files, Cargo.toml, go.mod, requirements.txt, .github/workflows, Makefile, git configuration, recent branch names, existing CLAUDE.md content. Detection produces values with confidence levels: high-confidence, medium-confidence, low-confidence, or default.

**Layer two: derived state.** The detector's output lives at .preflight/derived/state.json in the team's repo. Generated, not authored. Regenerated when inputs change. Gitignored by default. Hooks and skills read derived state for the values they need.

**Layer three: natural-language overrides in CLAUDE.md.** Where the team deviates from auto-detected values, they express it in natural language in CLAUDE.md. The framework extracts overrides via model interpretation at session-start. Extracted overrides merge into derived state.

**Bootstrap captures all of this.** Bootstrap runs the detector, surfaces detected values to the lead, proactively asks about overrides, captures preferences as natural-language statements in CLAUDE.md, commits everything together when alignment is explicit.

**Five verification mechanisms eliminate silent failure:**

Confidence-rated detection. Low-confidence values trigger explicit verification before use.

Drift detection. At session-start, framework re-runs detection, compares against cached derived state, surfaces drift.

Sanity checks at use sites. Hooks and skills validate derived values before acting on them.

Verbose mode for high-stakes operations. Before push, PR creation, rubric edit, the framework surfaces what derived values it is about to use.

Audit trail of derived state usage. Every framework operation logs which values it consumed.

### How team content evolves

Two evolution mechanisms, each disciplined:

**CLAUDE.md evolves through /preflight:bootstrap** in validate or update mode.

**Rubric evolves through /preflight:rubric-edit** PRs based on accumulated captures.

Both have the same discipline shape: framework-controlled process, surface findings explicitly, get team confirmation, commit on alignment. The framework never modifies team content outside these two mechanisms.

### When the contract is violated

If CLAUDE.md becomes stale, the framework's behavior degrades visibly. The lead notices and updates through bootstrap.

If the rubric stops being maintained, captures accumulate without promotion. The framework proactively warns.

If a captured finding is repeatedly missed but never promoted, the team is implicitly saying "this is not actually a rule we want to enforce." The framework respects this — the audit trail records the misses.

If the framework injects opinions the team did not author, that is a framework bug. Framework files and team files are structurally separated.

The contract works because both sides have clear obligations and visible failure modes.

---

## Section 4 — Skills, Sub-agents, and Hooks: The Framework's Surface

This section is the conceptual reference. Each component gets enough description for someone to understand what it does and where it fits. Exhaustive specification lives in the inventory document at docs/inventory-2026-05-21.md.

### The eight skills

**/preflight:bootstrap.** What it does: the team's onboarding ritual. Run by the lead engineer once per team adoption. Optionally re-run when CLAUDE.md needs validation or update. Operates in three modes — Generate, Validate, Update. Why it exists: CLAUDE.md is the team's bible; bootstrap makes it reliable through structured conversation with codebase analysis as ground truth. How it composes: sole mechanism for committing CLAUDE.md changes.

**/preflight:review.** What it does: read-only review of pending changes against the team's rubric. Produces findings classified by severity. Never edits, never pushes. Why it exists: engineers need feedback fast without invoking the full pipeline. How it composes: dispatches the reviewer sub-agent.

**/preflight:fix-and-close.** What it does: the core pipeline. Runs Stage 1 review loop locally, applies fixes through coupled-group protocol, pushes when clean, dispatches external-review handler for Stage 2, processes external findings through learning loop, lands clean PR. Why it exists: reviewing and fixing are coupled in practice. How it composes: dispatches reviewer, implementer, and external-review handler. Triggers pre-push and coupled-edit gates. Writes captures.

**/preflight:scaffold.** What it does: scaffolds new development. Reads team's generation specs, paste-don't-reconstructs the structure, adapts at marked points only, hands off to fix-and-close. Why it exists: enforces paste-don't-reconstruct mechanically so scaffolded code follows team's conventions reliably. How it composes: reads generation specs, hands off to fix-and-close.

**/preflight:migrate.** What it does: migration work with the framework's strict legacy-respect commitment. Discovery investigates legacy code with the analyst treating existing implementation as decisions-with-reasons. Execution surfaces tradeoff decisions. Every decision recorded in audit trail. Why it exists: migration is where the comfortable-modernization tendency is strongest; the framework's posture is the opposite. How it composes: dispatches analyst with legacy-intent investigation, activates GPS for tradeoffs, hands off to fix-and-close, writes to audit trail.

**/preflight:rubric-edit.** What it does: the mechanical side of the self-improvement loop. Reviews accumulated captures, proposes promotions, opens a rubric-edit PR. Lead reviews and merges. Why it exists: self-improvement requires a closing mechanism. How it composes: reads captures and rubric, produces PR, archives captures after merge.

**/preflight:gps-decide.** What it does: implements the GPS forcing function — Gaslight (raise stakes, force expert posture), Pushback (challenge generic answer, demand deeper insight), Stress Test (gap check, bias sweep, real stakes injection). Runs the model through these three stages mechanically. Why it exists: AI's default is helpful, confident, plausible. GPS interrupts the default through structured cognitive sequence. How it composes: activates directly when invoked or proactively when consequential-decision context detected.

**/preflight:routing.** What it does: not directly invoked. Loaded automatically by session-start hook. Provides decision tree for proactive skill suggestion. Why it exists: skills only help if engineers know when to use them. How it composes: loaded by session-start hook, sits passively in context.

### The four sub-agents

**Reviewer.** Role: read-only review against team's rubric. Boundaries: cannot edit, cannot push, cannot modify state. Returns CLEAN, NEEDS_FIXES, or ERROR. Dispatched by /preflight:review and /preflight:fix-and-close. Why isolated: review benefits from fresh context uncontaminated by design intentions.

**Analyst.** Role: read-only investigation with structured brief. For migration work, includes investigating legacy intent — searching ADRs, design documents, commit messages, comments. Boundaries: cannot edit, cannot push. Returns DONE, BLOCKED, or ERROR. Dispatched by /preflight:migrate for discovery; available to others. Why isolated: investigation needs fresh context to find what is actually in the codebase.

**Implementer.** Role: fix-only with structured brief. Edits only briefed files. Boundaries: cannot read outside brief scope, cannot push. Returns DONE or BLOCKED. Dispatched by /preflight:fix-and-close. Why isolated: implementation benefits from fresh context; auditability follows.

**External-review handler.** Role: the Stage 2 loop. Polls for external review (typically GitHub Copilot), classifies findings into four buckets, writes captures with FirstSeen and Cycles tracking. Returns SUCCESS, NEEDS_PARENT_FIXES, STUCK, DIVERGING, CAPPED, FAILED, or ERROR. Boundaries: reads PR state, writes captures, cannot edit code. Dispatched by /preflight:fix-and-close. Why isolated: Stage 2 loops can run for hours; isolation keeps long polling out of main session.

### The six hooks

**Session-start.** Trigger: Claude Code SessionStart event. Behavior: loads routing skill into session's additional context. Detects preflight configuration. Sets status line. Why: skills only activate proactively if routing is loaded.

**Pre-push gate.** Trigger: Bash PreToolUse event when command is git push. Behavior: reads evidence files in .preflight/gate/ for tests-pass, stage1-clean, map-validated states tied to current HEAD or immediate parent. Blocks push if any required evidence missing or stale. Why: the load-bearing gate ensuring work cannot ship without verification.

**Coupled-edit gate.** Trigger: Edit tool PreToolUse event. Behavior: reads .preflight/gate/active-groups.json. Blocks edits to unacknowledged coupled-group files. Why: coupled fixes must happen together to avoid regressions.

**Evidence writers.** Trigger: invoked by skills. Behavior: write evidence files to .preflight/gate/ recording tests-pass, stage1-clean, map-validated states. Why: pre-push gate needs evidence files to check.

**Group writers.** Trigger: invoked by skills. Behavior: write to .preflight/gate/active-groups.json to declare coupled groups and acknowledge them as fixed. Why: coupled-edit gate needs state file.

**Drift detector.** Trigger: Claude Code SessionStart event or on-demand. Behavior: re-runs detector module against current codebase, compares to cached derived state, surfaces drift to user. Why: configuration correctness depends on derived state matching codebase reality.

### What is not in Section 4

Exact input/output formats for sub-agents — in the inventory document.

Exact bash logic in hooks — in the source files, soon to be in refactored versions.

Exact skill prompt structure — in source files; refactor will update.

Section 4 is the conceptual map; the territory has additional resolution in the inventory document and source files.

### What this section commits us to

The eight skills, four sub-agents, six hooks listed here are the framework's surface. Adding new components requires architectural justification. The surface is bounded and the bounds are visible.

The refactor work that follows operates against this surface. Current preflight has variations that need to be reconciled — current scaffold-api becomes mature scaffold, current copilot-review-loop becomes external-review handler, current default rubrics get moved to examples. The refactor playbook at docs/refactor-playbook-2026-05-21.md makes those changes explicit.

After refactor, the framework's surface is exactly Section 4's catalog. That is the target.

---

## Sections 5+

Pending after refactor execution completes. Likely topics: adoption and getting started guide, operating model with worked examples, versioning policy when product matures, contribution model when ready for external participation.

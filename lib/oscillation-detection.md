# Oscillation, Divergence, and Cap Detection

Reference material for the `copilot-review-loop` agent and the `fix-and-close` skill. Defines termination conditions for review loops.

A prior migration ran **70+ Copilot review rounds** before human intervention. Post-mortem analysis showed rounds 9-70 produced net-zero convergence — issues were being shuffled between files via cascading regressions, not resolved. Hard caps exist to prevent this from recurring.

## Four Termination Conditions

### 1. Oscillation (STUCK)

**Definition:** The loop is doing the same work repeatedly without progress.

**Detection rules:**
- **Same files rule:** Two consecutive Stage 2 iterations modify exactly the same set of files. This suggests the reviewer is asking for X → undo X → X again.
- **Same line rule:** The same `(file, line)` is modified in N consecutive iterations (N from config, default 3). This is a literal back-and-forth rewrite.

**Action:** Report `STUCK` with evidence (which rule triggered, which files/lines, which iterations). Stop the loop. Surface to user.

### 2. Divergence (DIVERGING)

**Definition:** The loop is making changes but not converging toward clean. Total issue count is flat or growing.

**Detection rules:**
- Track total finding count per iteration: `findings[1], findings[2], ..., findings[N]`
- If `findings[N] >= findings[N-2]` (current is same-or-worse than 2 rounds ago) → DIVERGING warning
- If the warning persists for one more round (`findings[N+1] >= findings[N-1]`) → STUCK

**Why 2-round lookback:** A single round can temporarily increase findings (fixing issue A exposes hidden issue B). That's normal. But if after another round of fixes the count STILL isn't lower than where it was, the system is shuffling issues rather than resolving them.

**Action on first detection:** Emit DIVERGING warning. Continue one more round (benefit of the doubt).
**Action on persistence:** Report `STUCK` with the count history. Stop. Surface.

### 3. Hard Cap (CAPPED)

**Definition:** The loop has hit its maximum allowed iterations regardless of convergence behavior.

**Limits:**
- Stage 1 (pre-push review): **5 iterations maximum**
- Stage 2 (Copilot review): **8 iterations maximum**

**Rationale from data:** On a 70+ round migration, analysis showed:
- Rounds 1-4: genuine convergence (fixing real initial issues)
- Rounds 5-8: diminishing returns (fixing interaction effects)
- Rounds 9+: net-zero or negative progress (cascading regressions — fixing A breaks B, fixing B breaks C)

The caps are set at the boundary where the loop transitions from "productive" to "cascading." Rounds past the cap produce negative value — they introduce more issues than they resolve.

**Action:** Report `CAPPED` with:
- The iteration count history (showing finding counts per round)
- All remaining unresolved findings
- A recommendation to the user: "Remaining findings are likely architecturally coupled. Consider: (1) addressing them as a group in a fresh context, (2) accepting tech debt with an explicit plan, or (3) rethinking the approach."

### 4. Success (loop terminates normally)

**Definition:** External reviewer returns no actionable findings.
- Review state is `APPROVED`, or
- Zero unresolved comments newer than last push

**Action:** Report `SUCCESS`.

## State Tracking

The loop agent must maintain across iterations:
```
{
  "iterations": [
    {
      "round": 1,
      "filesModified": ["path/a.cs", "path/b.cs"],
      "linesModified": {"path/a.cs": [47, 52], "path/b.cs": [12]},
      "findingCount": 5
    },
    ...
  ]
}
```

This state is held in memory (not written to disk). It resets per `/fix-and-close` invocation.

## Escalation

When STUCK or DIVERGING is reported, the user's options are:
1. Address remaining findings as a group (not individually) — the structural approach
2. Accept the current state and push with known issues (tech debt acknowledgment)
3. Abandon the branch and rethink the approach
4. Request human review of the specific oscillating findings

The loop agent does NOT choose among these. It surfaces the evidence and stops.

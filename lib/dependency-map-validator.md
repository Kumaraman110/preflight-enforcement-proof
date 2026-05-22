# Dependency Map Validation

After the discovery-analyst generates `dependency-map.json`, the orchestrator MUST run this mechanical validation before consuming the map for coupling analysis. Do NOT trust LLM-generated structural claims without verification.

## Why This Exists

The discovery-analyst is a single LLM pass over the codebase. It misses coupling edges that require multi-hop tracing (A calls B through interface I, B is registered in Program.cs as the implementation of I, C also depends on I — so A and C are coupled through B). A single missed edge converts the coupled-group protocol from a cascade-prevention mechanism into a cascade-creation mechanism (by giving the orchestrator false confidence that findings are independent when they interact).

## Validation Steps (run as bash, ~5 seconds)

After `dependency-map.json` is produced at `<service-folder>/dependency-map.json`:

### Step 1: Independent files actually have no shared imports

For each file in the `independent` array, verify it does not `using` or import any namespace/type that also appears in a `couplingGroups` file.

```bash
# Extract types/namespaces imported by "independent" files
for indep_file in $(jq -r '.independent[]' dependency-map.json); do
  grep -oP '(?<=using )\S+(?=;)' "$indep_file" 2>/dev/null
done | sort -u > /tmp/indep-imports.txt

# Extract types/namespaces imported by coupled-group files
for group_file in $(jq -r '.couplingGroups[].files[]' dependency-map.json); do
  grep -oP '(?<=using )\S+(?=;)' "$group_file" 2>/dev/null
done | sort -u > /tmp/coupled-imports.txt

# Intersection = potential missed coupling
comm -12 /tmp/indep-imports.txt /tmp/coupled-imports.txt > /tmp/shared-imports.txt
```

If `/tmp/shared-imports.txt` is non-empty: WARN. List the shared imports. These files MAY be coupled — the orchestrator should treat them as coupled (conservative) unless the shared import is a framework namespace (e.g., `System.`, `Microsoft.Extensions.`).

### Step 2: Coupled groups have at least one verifiable call-chain edge

For each coupling group, verify that at least ONE pair of files in the group has a direct reference (method call, constructor injection, or type usage).

```bash
for group_idx in $(jq -r '.couplingGroups | keys[]' dependency-map.json); do
  files=($(jq -r ".couplingGroups[$group_idx].files[]" dependency-map.json))
  found_edge=false
  for i in "${!files[@]}"; do
    for j in "${!files[@]}"; do
      if [ "$i" -lt "$j" ]; then
        # Check if file_i references any type defined in file_j
        types_in_j=$(grep -oP '(?<=class |interface |record )\w+' "${files[$j]}" 2>/dev/null)
        for t in $types_in_j; do
          if grep -q "$t" "${files[$i]}" 2>/dev/null; then
            found_edge=true
            break 3
          fi
        done
      fi
    done
  done
  if [ "$found_edge" = false ]; then
    echo "WARNING: couplingGroup[$group_idx] has no verifiable call-chain edge"
    echo "  Files: ${files[*]}"
    echo "  Reason claimed: $(jq -r ".couplingGroups[$group_idx].reason" dependency-map.json)"
  fi
done
```

If a coupling group has NO verifiable edge: WARN. The group MAY be over-coupled (LLM inferred transitive coupling that doesn't exist). The orchestrator should still treat it as coupled (conservative — over-coupling is safe, under-coupling cascades).

### Step 3: DI registration cross-check

Check `Program.cs` (or wherever DI is registered) for service registrations. For each registered service, verify that its interface consumers appear in the same coupling group.

```bash
# Find all AddScoped/AddTransient/AddSingleton registrations
grep -oP '(?<=Add(?:Scoped|Transient|Singleton)<)I\w+,\s*\w+' Program.cs 2>/dev/null | while IFS=, read iface impl; do
  iface=$(echo "$iface" | tr -d ' ')
  impl=$(echo "$impl" | tr -d ' >')
  # Find files that inject $iface (constructor parameter of that type)
  consumers=$(grep -rl "$iface" --include="*.cs" . 2>/dev/null | grep -v Program.cs | grep -v "$impl")
  impl_file=$(grep -rl "class $impl" --include="*.cs" . 2>/dev/null | head -1)
  
  if [ -n "$consumers" ] && [ -n "$impl_file" ]; then
    # These files are coupled through DI — verify they're in the same group
    for consumer in $consumers; do
      in_same_group=$(jq -r --arg a "$impl_file" --arg b "$consumer" '
        .couplingGroups[] | select(.files | (contains([$a]) and contains([$b]))) | .reason
      ' dependency-map.json)
      if [ -z "$in_same_group" ]; then
        echo "COUPLING MISSED: $impl_file and $consumer share DI interface $iface but are not in the same coupling group"
      fi
    done
  fi
done
```

If DI coupling is missed: this is a HIGH-SEVERITY warning. DI-graph coupling is the #1 source of missed edges (3-hop: registration → interface → consumer). The orchestrator MUST add these files to the same coupling group before proceeding.

## Validation Outcomes

| Result | Action |
|---|---|
| All checks pass, no warnings | Consume map as-is |
| Step 1 warnings (shared imports) | Move warned files from `independent` to a new coupling group with reason "shared-import validation" |
| Step 2 warnings (unverifiable group) | Keep the group (conservative) but log for human review |
| Step 3 warnings (missed DI coupling) | MERGE the affected files into the same coupling group immediately |

## When Validation Itself Fails

If the bash checks fail (file not found, jq parse error, etc.): fall back to CONSERVATIVE coupling — treat ALL findings as one coupled group. This is slow (one giant implementer brief) but safe (no cascade possible). Log the validation failure for debugging.

## Integration Point

The fix-and-close orchestrator runs this validation:
- After discovery-analyst generates the map (migrate flow)
- After post-Phase-2 dependency map refresh
- NEVER skip validation because "the map looks reasonable" — that's the exact rationalization that leads to silent cascades

# TODOs

## Revisit Codex External Approval Parity

**What:** Revisit Codex external approval parity if OpenAI exposes a stable supported interface.

**Why:** External approval is one of the highest-value Claude Island behaviors, but Codex does not currently document an equivalent control loop.

**Pros:**
- Preserves a clear path to the most powerful future UX if the platform evolves.
- Prevents the same blocked idea from being rediscovered without context later.

**Cons:**
- It is blocked work and may remain blocked for a while.
- If revisited too early, it may tempt unsupported hacks around approval behavior.

**Context:** This review scoped v1 to Codex monitoring, attention-routing, transcript-backed history, and Codex-first UI. We explicitly rejected v1 approval parity because official Codex hooks do not currently expose a stable external approval-response mechanism. This TODO exists so future work starts from the real platform constraint instead of assuming parity should have been easy.

**Depends on / blocked by:** Blocked by official Codex documentation or supported APIs for external approval control.

## Post-v1 Cleanup Of Claude-First Legacy

**What:** Evaluate a post-v1 cleanup pass to reduce or remove leftover Claude-first code and branding that no longer serve the Codex-first product.

**Why:** The review chose a minimal-diff path for v1, which intentionally leaves some Claude-oriented names, seams, and assumptions in place.

**Pros:**
- Creates a clear path to simplify the codebase after Codex support lands.
- Prevents temporary compatibility shims from becoming permanent design debt.

**Cons:**
- May not be worth doing if Claude compatibility remains useful.
- Can turn into churn-heavy cleanup if prioritized before usage data justifies it.

**Context:** This review explicitly chose surgical renames, shared state, and a minimal component budget for v1. That was the right shipping tradeoff, but it leaves intentional naming and compatibility debt behind. This TODO makes it clear that the debt was accepted on purpose, not missed.

**Depends on / blocked by:** Best revisited after Codex v1 ships and real usage clarifies whether Claude compatibility is still worth carrying.

## Finish Internal Rename Cleanup

**What:** Finish the remaining internal rename surfaces that still intentionally say Claude after the external product rename to Codex Island.

**Why:** User-facing branding now says Codex Island, but the codebase still carries Claude-first identifiers in target names, bundle identifiers, hook compatibility layers, comments, logger subsystems, and script paths. Some of that debt is acceptable; some of it will keep causing confusion if left indefinitely.

**Pros:**
- Reduces confusion between the app's public identity and its internal implementation.
- Creates a cleaner base for future work on packaging, releases, and long-term maintenance.

**Cons:**
- Some rename surfaces are compatibility-sensitive, especially bundle identifiers, hook script paths, socket names, and updater infrastructure.
- A full cleanup can become churn-heavy if it is not split into compatibility-safe slices.

**Context:** External product surfaces, release scripts, and live Codex title/messaging improvements are already shipped. What remains is the deliberate internal debt: `ClaudeIsland` target/module naming, Claude-oriented comments and docs, logger subsystem names, Claude hook compatibility pieces, and fallback identifiers that should be audited instead of blindly renamed.

**Depends on / blocked by:** Best handled incrementally, with each slice evaluated for compatibility risk before renaming.

## Verify Rename-Related Update Infrastructure

**What:** Verify that Sparkle/appcast/release automation still points to the correct production endpoints after the Codex Island rename.

**Why:** The external product rename updated names and GitHub release references, but update feeds and website-backed release infrastructure can still break if they remain on legacy Claude Island endpoints.

**Pros:**
- Reduces the risk of shipping a renamed app with broken update discovery or release publishing.
- Clarifies which deployment surfaces must stay on legacy names temporarily and which should move now.

**Cons:**
- May require coordination with website/appcast hosting outside this repo.
- Some endpoints may need to stay on legacy domains until migration is complete.

**Context:** Release scripts now target the Codex Island repository and product name, but `Info.plist` still points Sparkle at `https://claudeisland.com/appcast.xml`. That may be intentional, or it may be stale; it needs verification instead of assumption.

**Depends on / blocked by:** Depends on whoever owns appcast hosting, release publishing, and the website/release delivery path.

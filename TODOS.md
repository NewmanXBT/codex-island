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

## Improve Session Title Summaries

**What:** Improve session title generation so each session title is brief, context-aware, and reliably summarizes the actual task.

**Why:** The current title derivation is useful but still too literal in some cases. The top-level session list needs short, high-signal labels that stay readable at a glance.

**Pros:**
- Makes the session list and notch much easier to scan during a busy Codex workflow.
- Reduces ambiguity when multiple sessions are open in the same repo or related repos.

**Cons:**
- Over-aggressive summarization can hide useful detail or create misleading titles.
- Good summarization likely needs iteration against real transcripts rather than one static heuristic.

**Context:** Current Codex title generation exists, but the product bar should be higher: titles should be compact and context-rich, not just truncated prompts.

**Depends on / blocked by:** Depends on transcript examples and title-quality iteration, not blocked on platform APIs.

## Fix Outbound Messaging To Live Sessions

**What:** Fix sending messages from the app into live sessions so the chat input reliably works during normal use.

**Why:** Typing into the session from the app is a core part of the product loop. If input is unreliable or unavailable, the chat UI feels incomplete.

**Pros:**
- Unlocks a real "stay in the island" workflow instead of forcing terminal context switches.
- Makes Codex session monitoring feel interactive rather than read-only.

**Cons:**
- Terminal routing is fragile across terminal apps, tmux, focus state, permissions, and TTY discovery.
- A naive implementation could send text to the wrong terminal or fail silently.

**Context:** There is partial wiring for live session messaging, but it is not yet working reliably enough to count as shipped behavior.

**Depends on / blocked by:** Depends on terminal targeting, accessibility/AppleScript behavior, and live-session routing correctness.

## Rename Product To Codex Island

**What:** Rename the product, repo, bundle-facing copy, and release artifacts from "Claude Island" to "Codex Island".

**Why:** The fork is now explicitly Codex-first. Keeping the Claude-first name creates product confusion and makes the current direction look half-finished.

**Pros:**
- Aligns the product name with the actual target workflow and roadmap.
- Removes needless brand ambiguity in the UI, docs, and repository.

**Cons:**
- Renaming touches user-facing copy, package metadata, bundle identifiers, release assets, and documentation.
- Some compatibility seams may still intentionally reference Claude internally for a while.

**Context:** The current implementation is already moving toward a Codex-first product, but the external identity still says Claude Island in many places.

**Depends on / blocked by:** Best done as a coordinated cleanup pass after deciding which legacy Claude compatibility should remain.

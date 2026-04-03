# Codex-First Fork Plan

## Goal

Turn Claude Island into a Codex-first macOS companion for daily use.

This is no longer planned as a general multi-provider agent monitor in v1. The primary goal is to replace the Claude-first assumptions in the app with a Codex-first workflow, while preserving Claude compatibility only where it is cheap and does not add meaningful complexity.

## Product Direction

This fork is optimized for one real use case:

- the user primarily works in Codex
- the app should stay open all day
- the app should surface Codex session state, recent activity, and "you need to look now" moments without constant terminal switching

This is not a rebrand-only project. It is a protocol and product adaptation from Claude-first behavior to Codex-first behavior.

## Current State

The app is tightly coupled to Claude Code in four places:

1. Hook installation and transport
   - `ClaudeIsland/Services/Hooks/HookInstaller.swift`
   - `ClaudeIsland/Resources/claude-island-state.py`
   - `ClaudeIsland/Services/Hooks/HookSocketServer.swift`
   - Assumes `~/.claude/hooks/`, `~/.claude/settings.json`, and Claude hook event names.

2. Session transcript parsing
   - `ClaudeIsland/Services/Session/ConversationParser.swift`
   - `ClaudeIsland/Services/Session/JSONLInterruptWatcher.swift`
   - `ClaudeIsland/Services/Session/AgentFileWatcher.swift`
   - Assumes Claude JSONL layout under `~/.claude/projects/...`, including `tool_use`, `tool_result`, `summary`, and `agent-*.jsonl`.

3. Domain model naming and state semantics
   - `ClaudeIsland/Models/SessionState.swift`
   - `ClaudeIsland/Models/SessionEvent.swift`
   - `ClaudeIsland/Services/State/SessionStore.swift`
   - State is generic enough to reuse, but many comments and transitions assume Claude-only events and approval behavior.

4. UI copy and product framing
   - `README.md`
   - `ClaudeIsland/UI/Views/ClaudeInstancesView.swift`
   - `ClaudeIsland/UI/Views/ChatView.swift`
   - `ClaudeIsland/Core/NotchActivityCoordinator.swift`
   - Product language, empty states, and icons are Claude-branded.

## Codex Facts To Design Around

Based on the local Codex install on this machine and official OpenAI Codex documentation:

- Codex supports hooks via `~/.codex/hooks.json`.
- Codex also supports project-level hooks via repo-local `.codex/hooks.json`.
- Codex session history is stored under `~/.codex/sessions/YYYY/MM/DD/*.jsonl`.
- Codex session JSONL records use a different schema from Claude, including:
  - `session_meta`
  - `event_msg`
  - `response_item`
  - `response_item.function_call`
  - `response_item.function_call_output`
  - `agent_message`
- Codex official hooks include:
  - `SessionStart`
  - `UserPromptSubmit`
  - `PreToolUse`
  - `PostToolUse`
  - `Stop`
- Codex hook payloads include session metadata such as:
  - `session_id`
  - `cwd`
  - `transcript_path`
  - `model`
- Codex approvals are not the same as Claude's `PermissionRequest` response loop.

## Hard Limits From Official Codex Docs

These are the main capability constraints that shape the implementation:

1. No official external approval-response loop
   - Claude Island currently depends on a synchronous request-response approval path.
   - Codex official hooks do not document an equivalent external approval channel.
   - `PreToolUse` can block in supported cases, but the official docs do not expose a stable "external UI approves and resumes tool" flow like the Claude implementation relies on.

2. Tool hooks are not universal
   - Official Codex docs currently document `PreToolUse` and `PostToolUse` support for Bash.
   - There is no stable official guarantee that every Codex tool or connector emits the same hook lifecycle.

3. Post-tool hooks cannot undo side effects
   - Even where `PostToolUse` is available, the command has already executed.
   - This means the app can observe or annotate, but not reverse tool side effects after the fact.

## What This Means In Practice

The app can confidently support:

- session discovery
- processing / waiting status
- recent message preview
- Bash-oriented tool activity
- transcript-driven chat history
- notifications / sound / attention moments
- terminal or tmux focus actions

The app cannot confidently promise full Claude-equivalent support for:

- external approval buttons that resume Codex from the notch
- universal tool lifecycle coverage across all Codex tools
- stable subagent visualization parity based only on official APIs

So "full parity" must be interpreted as:

- parity for the useful user-facing experience where Codex exposes enough signal
- graceful degradation where Codex does not expose an equivalent control surface

## Recommended Architecture

Because this is now a Codex-first fork rather than a generic platform project, the architecture should minimize abstraction and minimize diff size while still isolating the protocol differences that matter.

### 1. Prefer A Thin Provider Boundary, Not A Full Platform

Do not start with a heavyweight "agent platform" abstraction layer.

Recommended shape:

- keep one shared app state model
- isolate only the pieces that are provably protocol-specific:
  - hook install / hook event adaptation
  - transcript path resolution
  - transcript parsing
  - session file watching

This is enough to support Codex cleanly without spending an unnecessary innovation token on a generic provider framework.

### 2. Normalize Into One Internal Event Model

Keep `SessionState` as the shared runtime state, but add minimal provider metadata:

- `provider: .claude | .codex`
- `providerSessionPath`
- `providerDisplayName`

Add a normalized event type that both providers can emit:

- session started
- user prompt submitted
- assistant processing
- tool started
- tool completed
- waiting for user input
- waiting for approval
- session ended
- subagent started
- subagent completed

Codex hooks and Codex transcript updates should both map into this normalized model.

### 3. Split Transport From Parsing

Current code mixes transport assumptions with transcript assumptions. Separate them:

- Transport:
  - Claude: existing socket events from hook script
  - Codex: hook command output plus filesystem observation
- Transcript:
  - Claude transcript parser for `~/.claude/projects/...`
  - Codex transcript parser for `~/.codex/sessions/...`

This matters because Codex support will be transcript-driven for several features even after hooks are installed.

## Codex-First Data Flow

```text
Codex CLI
  |
  | hooks.json events
  v
Codex hook adapter
  |
  v
Normalized session events ---> SessionStore ---> Notch/UI/session list
  ^
  |
  | transcript_path + file watching
  |
Codex transcript parser
```

Important consequence:

- hooks give low-latency lifecycle hints
- transcript parsing fills in history and tool detail
- some "parity" features must be transcript-backed rather than hook-controlled

## Delivery Plan

### Phase 1: Make The Core Codex-Ready With Minimal Abstraction

Outcome:
The app is still behaviorally Claude-oriented, but the code paths that block Codex support are isolated.

Work:

- Rename Claude-specific core types only where the naming would actively fight a Codex-first future.
- Add `ProviderKind` enum and attach it to `SessionState`.
- Extract transcript path-building logic out of `ConversationParser`.
- Split hook install and transcript parsing into protocol-specific components.
- Move Claude hook install logic behind a `ClaudeHookInstaller`.
- Introduce Codex-specific components only for the paths that truly differ.

Definition of done:

- No generic framework is introduced unless at least two concrete implementations need it.
- The diff stays small enough that the app still feels like the same codebase, not a rewrite.

### Phase 2: Codex Monitoring MVP

Outcome:
The app becomes useful for a real Codex-heavy workflow.

Work:

- Implement `CodexSessionLocator` for `~/.codex/sessions`.
- Implement `CodexTranscriptParser`.
- Map these Codex records into existing `ChatHistoryItem` and tool status models:
  - `session_meta` -> session bootstrap
  - `agent_message` -> assistant chat items
  - `response_item.function_call` -> tool start
  - `response_item.function_call_output` -> tool completion
  - `event_msg.user_message` -> user chat items
- Build a Codex file watcher similar to the current Claude JSONL watchers, but keyed to the Codex session file layout.
- Add Codex branding, copy, and iconography where the current UI is explicitly Claude-branded.
- Preserve terminal focus and tmux-focus workflows where they already work.

Definition of done:

- A live Codex session appears in the UI.
- The session title, last message, and tool timeline update as the JSONL file grows.
- The app is worth leaving open during a normal Codex session.

### Phase 3: Codex Hooks Integration

Outcome:
The app receives low-latency Codex lifecycle signals instead of relying only on transcript polling.

Work:

- Add a Codex hook installer for `~/.codex/hooks.json`.
- Ship a dedicated Codex hook script/binary in app resources.
- Translate Codex hook payloads into normalized internal events.
- Use hooks for:
  - startup/resume
  - user prompt submit
  - pre-tool
  - post-tool
  - stop

Definition of done:

- Codex sessions become visible immediately on start.
- Tool state transitions do not depend entirely on file tailing latency.

### Phase 4: Interaction Strategy Under Codex Limits

Outcome:
The app handles Codex attention moments correctly, even where Claude-style external control is impossible.

Work:

- Detect Codex states that require human attention.
- Focus the correct terminal or tmux pane.
- Support safe send-message flows only where they are reliable.
- If future official Codex docs expose a stable external approval mechanism, add notch approvals then.

Recommendation:

- Treat external notch approval parity as explicitly out of scope for v1.
- Ship Codex monitoring and attention-routing first.
- Only add external approval controls if OpenAI documents a stable supported interface.

### Phase 5: Product And Branding Cleanup

Outcome:
The app no longer feels like a Claude app with Codex pasted on top.

Work:

- Update README and in-app copy to reflect Codex-first positioning.
- Replace UI copy such as "Run claude in terminal" with Codex-first language.
- Replace Claude-only affordances, colors, and empty states where they no longer match the primary workflow.
- Decide whether the repository and app should be renamed in a later pass.

## File-Level Change List

Likely first-pass changes:

- `ClaudeIsland/Models/SessionState.swift`
- `ClaudeIsland/Models/SessionEvent.swift`
- `ClaudeIsland/Services/State/SessionStore.swift`
- `ClaudeIsland/Services/Session/ConversationParser.swift`
- `ClaudeIsland/Services/Session/JSONLInterruptWatcher.swift`
- `ClaudeIsland/Services/Session/AgentFileWatcher.swift`
- `ClaudeIsland/Services/Hooks/HookInstaller.swift`
- `ClaudeIsland/Services/Hooks/HookSocketServer.swift`
- `ClaudeIsland/UI/Views/ClaudeInstancesView.swift`
- `ClaudeIsland/UI/Views/ChatView.swift`
- `README.md`

Likely new files:

- `ClaudeIsland/Models/ProviderKind.swift`
- `ClaudeIsland/Services/Providers/Claude/ClaudeProvider.swift`
- `ClaudeIsland/Services/Providers/Codex/CodexProvider.swift`
- `ClaudeIsland/Services/Providers/Codex/CodexHookInstaller.swift`
- `ClaudeIsland/Services/Providers/Codex/CodexTranscriptParser.swift`
- `ClaudeIsland/Services/Providers/Codex/CodexSessionWatcher.swift`

## Risks

1. External approval parity does not currently exist as a stable documented Codex capability
   - The current Claude notch approval interaction cannot simply be ported.
   - Overpromising parity here would create a fake milestone.

2. Subagent semantics differ
   - Claude uses Task subagents and `agent-*.jsonl`.
   - Codex subagents and guardian flows appear in session metadata differently.

3. Transcript-driven features are more brittle than hook-driven ones
   - If the Codex transcript schema changes, history and tool rendering may drift.

4. Over-abstraction risk
   - Building a full provider platform now would be classic over-engineering for a Codex-first fork.

5. Naming debt
   - "ClaudeIsland" remains an implementation smell once Codex becomes the main workflow.

## Recommended MVP

Build the Codex-first fork in this order:

1. Minimal core refactor to isolate Claude-specific protocol code
2. Codex session detection and transcript rendering
3. Codex hooks for low-latency lifecycle updates
4. Codex attention-routing and terminal focus flows
5. External approval support only if Codex exposes a stable documented interface

## Explicitly Not Promised In V1

- Claude-style notch approval buttons that resume Codex tools
- universal hook coverage for every Codex tool type
- guaranteed subagent parity with Claude's Task-based UI
- a fully generic provider framework

## Sources

- OpenAI Codex hooks docs
- OpenAI Codex config reference
- OpenAI Codex approvals/security docs
- OpenAI Codex subagents docs

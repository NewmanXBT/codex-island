//
//  SessionState.swift
//  ClaudeIsland
//
//  Unified state model for a Claude session.
//  Consolidates all state that was previously spread across multiple components.
//

import Foundation

enum ProviderKind: String, Codable, Sendable, Equatable, CaseIterable {
    case claude
    case codex

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }
}

/// Complete state for a single Claude session
/// This is the single source of truth - all state reads and writes go through SessionStore
struct SessionState: Equatable, Identifiable, Sendable {
    // MARK: - Identity

    let sessionId: String
    let cwd: String
    let projectName: String
    let provider: ProviderKind

    // MARK: - Instance Metadata

    var pid: Int?
    var tty: String?
    var isInTmux: Bool

    // MARK: - State Machine

    /// Current phase in the session lifecycle
    var phase: SessionPhase

    // MARK: - Chat History

    /// All chat items for this session (replaces ChatHistoryManager.histories)
    var chatItems: [ChatHistoryItem]

    // MARK: - Tool Tracking

    /// Unified tool tracker (replaces 6+ dictionaries in ChatHistoryManager)
    var toolTracker: ToolTracker

    // MARK: - Subagent State

    /// State for Task tools and their nested subagent tools
    var subagentState: SubagentState

    // MARK: - Conversation Info (from JSONL parsing)

    var conversationInfo: ConversationInfo

    // MARK: - Clear Reconciliation

    /// When true, the next file update should reconcile chatItems with parser state
    /// This removes pre-/clear items that no longer exist in the JSONL
    var needsClearReconciliation: Bool

    // MARK: - Timestamps

    var lastActivity: Date
    var createdAt: Date

    // MARK: - Identifiable

    var id: String { sessionId }

    // MARK: - Initialization

    nonisolated init(
        sessionId: String,
        cwd: String,
        projectName: String? = nil,
        provider: ProviderKind = .claude,
        pid: Int? = nil,
        tty: String? = nil,
        isInTmux: Bool = false,
        phase: SessionPhase = .idle,
        chatItems: [ChatHistoryItem] = [],
        toolTracker: ToolTracker = ToolTracker(),
        subagentState: SubagentState = SubagentState(),
        conversationInfo: ConversationInfo = ConversationInfo(
            summary: nil, lastMessage: nil, lastMessageRole: nil,
            lastToolName: nil, firstUserMessage: nil, lastUserMessageDate: nil
        ),
        needsClearReconciliation: Bool = false,
        lastActivity: Date = Date(),
        createdAt: Date = Date()
    ) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.projectName = projectName ?? URL(fileURLWithPath: cwd).lastPathComponent
        self.provider = provider
        self.pid = pid
        self.tty = tty
        self.isInTmux = isInTmux
        self.phase = phase
        self.chatItems = chatItems
        self.toolTracker = toolTracker
        self.subagentState = subagentState
        self.conversationInfo = conversationInfo
        self.needsClearReconciliation = needsClearReconciliation
        self.lastActivity = lastActivity
        self.createdAt = createdAt
    }

    // MARK: - Derived Properties

    /// Whether this session needs user attention
    var needsAttention: Bool {
        phase.needsAttention
    }

    /// The active permission context, if any
    var activePermission: PermissionContext? {
        if case .waitingForApproval(let ctx) = phase {
            return ctx
        }
        return nil
    }

    // MARK: - UI Convenience Properties

    /// Stable identity for SwiftUI (combines PID and sessionId for animation stability)
    var stableId: String {
        if let pid = pid {
            return "\(pid)-\(sessionId)"
        }
        return sessionId
    }

    /// Display title: summary > first user message > project name
    var displayTitle: String {
        formattedDisplayTitle(
            summary: conversationInfo.summary,
            firstUserMessage: conversationInfo.firstUserMessage,
            projectName: projectName,
            provider: provider
        )
    }

    /// Provider label for badges/copy
    var providerDisplayName: String {
        provider.displayName
    }

    /// Best hint for matching window title
    var windowHint: String {
        conversationInfo.summary ?? projectName
    }

    /// Pending tool name if waiting for approval
    var pendingToolName: String? {
        activePermission?.toolName
    }

    /// Pending tool use ID
    var pendingToolId: String? {
        activePermission?.toolUseId
    }

    /// Formatted pending tool input for display
    var pendingToolInput: String? {
        activePermission?.formattedInput
    }

    /// Last message content
    var lastMessage: String? {
        conversationInfo.lastMessage
    }

    /// Last message role
    var lastMessageRole: String? {
        conversationInfo.lastMessageRole
    }

    /// Last tool name
    var lastToolName: String? {
        conversationInfo.lastToolName
    }

    /// Summary
    var summary: String? {
        conversationInfo.summary
    }

    /// First user message
    var firstUserMessage: String? {
        conversationInfo.firstUserMessage
    }

    /// Last user message date
    var lastUserMessageDate: Date? {
        conversationInfo.lastUserMessageDate
    }

    /// Whether the session can be interacted with
    var canInteract: Bool {
        phase.needsAttention
    }

    /// Whether the session is actively running tools or subagents.
    var isWorking: Bool {
        !toolTracker.inProgress.isEmpty || subagentState.hasActiveSubagent
    }

    /// Explicit short status text for cards and notch surfaces
    var cardStatusText: String {
        switch phase {
        case .processing:
            return isWorking ? "Working" : "Processing"
        case .compacting:
            return "Compacting context"
        case .waitingForInput:
            return "Needs next step"
        case .waitingForApproval(let context):
            return context.toolName == "AskUserQuestion" ? "Needs your input" : "Waiting for approval"
        case .idle:
            return "Idle"
        case .ended:
            return "Ended"
        }
    }

    /// Deduplicated detail text for cards. Hides content that simply repeats the title/summary.
    var cardDetailText: String? {
        guard let message = lastMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
              !message.isEmpty else {
            return nil
        }

        if isDuplicateCardText(message, comparedWith: displayTitle)
            || isDuplicateCardText(message, comparedWith: summary)
            || isDuplicateCardText(message, comparedWith: firstUserMessage) {
            return nil
        }

        switch lastMessageRole {
        case "tool":
            if let lastToolName {
                let toolLabel = MCPToolFormatter.formatToolName(lastToolName)
                return message.isEmpty ? toolLabel : "\(toolLabel) \(message)"
            }
            return message
        case "user":
            return "You: \(message)"
        default:
            return message
        }
    }
}

private func formattedDisplayTitle(
    summary: String?,
    firstUserMessage: String?,
    projectName: String,
    provider: ProviderKind
) -> String {
    let cleanedSummary = cleanedTitleCandidate(summary)
    let cleanedFirstMessage = cleanedTitleCandidate(firstUserMessage)

    switch provider {
    case .claude:
        return cleanedSummary ?? cleanedFirstMessage ?? projectName
    case .codex:
        if let cleanedSummary, cleanedSummary.caseInsensitiveCompare(projectName) != .orderedSame {
            return "\(projectName) · \(cleanedSummary)"
        }
        if let cleanedFirstMessage, cleanedFirstMessage.caseInsensitiveCompare(projectName) != .orderedSame {
            return "\(projectName) · \(cleanedFirstMessage)"
        }
        return projectName
    }
}

private func cleanedTitleCandidate(_ raw: String?) -> String? {
    guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
        return nil
    }

    text = text.replacingOccurrences(of: "\n", with: " ")
    text = text.replacingOccurrences(of: "\t", with: " ")

    while text.contains("  ") {
        text = text.replacingOccurrences(of: "  ", with: " ")
    }

    let separators = [". ", "。", ":", " - ", " | "]
    for separator in separators {
        if let range = text.range(of: separator) {
            let prefix = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if prefix.count >= 8 {
                text = prefix
                break
            }
        }
    }

    let noisyPrefixes = [
        "you need to",
        "please",
        "help me",
        "can you",
        "could you",
        "i want to",
        "we need to",
        "take this repo",
        "fix this",
        "implement",
        "another language model started"
    ]

    let lowercased = text.lowercased()
    for prefix in noisyPrefixes {
        if lowercased.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
            break
        }
    }

    if text.hasPrefix("http://") || text.hasPrefix("https://") || text.hasPrefix("{") || text.hasPrefix("#") {
        return nil
    }

    if text.count < 6 {
        return nil
    }

    if text.count > 44 {
        text = String(text.prefix(41)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }

    return text.isEmpty ? nil : text
}

private func isDuplicateCardText(_ lhs: String?, comparedWith rhs: String?) -> Bool {
    guard let left = normalizedCardComparisonText(lhs),
          let right = normalizedCardComparisonText(rhs) else {
        return false
    }

    return left == right || left.hasSuffix(right) || right.hasSuffix(left)
}

private func normalizedCardComparisonText(_ raw: String?) -> String? {
    guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
          !text.isEmpty else {
        return nil
    }

    if let separatorRange = text.range(of: "·") {
        text = String(text[separatorRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    text = text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))

    return text.isEmpty ? nil : text
}

// MARK: - Tool Tracker

/// Unified tool tracking - replaces multiple dictionaries in ChatHistoryManager
struct ToolTracker: Equatable, Sendable {
    /// Tools currently in progress, keyed by tool_use_id
    var inProgress: [String: ToolInProgress]

    /// All tool IDs we've seen (for deduplication)
    var seenIds: Set<String>

    /// Last JSONL file offset for incremental parsing
    var lastSyncOffset: UInt64

    /// Last sync timestamp
    var lastSyncTime: Date?

    nonisolated init(
        inProgress: [String: ToolInProgress] = [:],
        seenIds: Set<String> = [],
        lastSyncOffset: UInt64 = 0,
        lastSyncTime: Date? = nil
    ) {
        self.inProgress = inProgress
        self.seenIds = seenIds
        self.lastSyncOffset = lastSyncOffset
        self.lastSyncTime = lastSyncTime
    }

    /// Mark a tool ID as seen, returns true if it was new
    nonisolated mutating func markSeen(_ id: String) -> Bool {
        seenIds.insert(id).inserted
    }

    /// Check if a tool ID has been seen
    nonisolated func hasSeen(_ id: String) -> Bool {
        seenIds.contains(id)
    }

    /// Start tracking a tool
    nonisolated mutating func startTool(id: String, name: String) {
        guard markSeen(id) else { return }
        inProgress[id] = ToolInProgress(
            id: id,
            name: name,
            startTime: Date(),
            phase: .running
        )
    }

    /// Complete a tool
    nonisolated mutating func completeTool(id: String, success: Bool) {
        inProgress.removeValue(forKey: id)
    }
}

/// A tool currently in progress
struct ToolInProgress: Equatable, Sendable {
    let id: String
    let name: String
    let startTime: Date
    var phase: ToolInProgressPhase
}

/// Phase of a tool in progress
enum ToolInProgressPhase: Equatable, Sendable {
    case starting
    case running
    case pendingApproval
}

// MARK: - Subagent State

/// State for Task (subagent) tools
struct SubagentState: Equatable, Sendable {
    /// Active Task tools, keyed by task tool_use_id
    var activeTasks: [String: TaskContext]

    /// Ordered stack of active task IDs (most recent last) - used for proper tool assignment
    /// When multiple Tasks run in parallel, we use insertion order rather than timestamps
    var taskStack: [String]

    /// Mapping of agentId to Task description (for AgentOutputTool display)
    var agentDescriptions: [String: String]

    nonisolated init(activeTasks: [String: TaskContext] = [:], taskStack: [String] = [], agentDescriptions: [String: String] = [:]) {
        self.activeTasks = activeTasks
        self.taskStack = taskStack
        self.agentDescriptions = agentDescriptions
    }

    /// Whether there's an active subagent
    nonisolated var hasActiveSubagent: Bool {
        !activeTasks.isEmpty
    }

    /// Start tracking a Task tool
    nonisolated mutating func startTask(taskToolId: String, description: String? = nil) {
        activeTasks[taskToolId] = TaskContext(
            taskToolId: taskToolId,
            startTime: Date(),
            agentId: nil,
            description: description,
            subagentTools: []
        )
    }

    /// Stop tracking a Task tool
    nonisolated mutating func stopTask(taskToolId: String) {
        activeTasks.removeValue(forKey: taskToolId)
    }

    /// Set the agentId for a Task (called when agent file is discovered)
    nonisolated mutating func setAgentId(_ agentId: String, for taskToolId: String) {
        activeTasks[taskToolId]?.agentId = agentId
        if let description = activeTasks[taskToolId]?.description {
            agentDescriptions[agentId] = description
        }
    }

    /// Add a subagent tool to a specific Task by ID
    nonisolated mutating func addSubagentToolToTask(_ tool: SubagentToolCall, taskId: String) {
        activeTasks[taskId]?.subagentTools.append(tool)
    }

    /// Set all subagent tools for a specific Task (used when updating from agent file)
    nonisolated mutating func setSubagentTools(_ tools: [SubagentToolCall], for taskId: String) {
        activeTasks[taskId]?.subagentTools = tools
    }

    /// Add a subagent tool to the most recent active Task
    nonisolated mutating func addSubagentTool(_ tool: SubagentToolCall) {
        // Find most recent active task (for parallel Task support)
        guard let mostRecentTaskId = activeTasks.keys.max(by: {
            (activeTasks[$0]?.startTime ?? .distantPast) < (activeTasks[$1]?.startTime ?? .distantPast)
        }) else { return }

        activeTasks[mostRecentTaskId]?.subagentTools.append(tool)
    }

    /// Update the status of a subagent tool across all active Tasks
    nonisolated mutating func updateSubagentToolStatus(toolId: String, status: ToolStatus) {
        for taskId in activeTasks.keys {
            if let index = activeTasks[taskId]?.subagentTools.firstIndex(where: { $0.id == toolId }) {
                activeTasks[taskId]?.subagentTools[index].status = status
                return
            }
        }
    }
}

/// Context for an active Task tool
struct TaskContext: Equatable, Sendable {
    let taskToolId: String
    let startTime: Date
    var agentId: String?
    var description: String?
    var subagentTools: [SubagentToolCall]
}

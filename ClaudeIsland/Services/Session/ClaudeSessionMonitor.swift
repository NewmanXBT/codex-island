//
//  ClaudeSessionMonitor.swift
//  ClaudeIsland
//
//  MainActor wrapper around SessionStore for UI binding.
//  Publishes SessionState arrays for SwiftUI observation.
//

import AppKit
import Combine
import Foundation

@MainActor
class SessionMonitor: ObservableObject {
    @Published var instances: [SessionState] = []
    @Published var pendingInstances: [SessionState] = []

    private let codexRefreshInterval: TimeInterval = 5
    private var cancellables = Set<AnyCancellable>()
    private var codexRefreshTimer: Timer?

    init() {
        SessionStore.shared.sessionsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessions in
                self?.updateFromSessions(sessions)
            }
            .store(in: &cancellables)

        InterruptWatcherManager.shared.delegate = self
    }

    // MARK: - Monitoring Lifecycle

    func startMonitoring() {
        Task {
            await refreshCodexSessions()
        }

        startCodexRefreshTimer()

        HookSocketServer.shared.start(
            onEvent: { event in
                Task {
                    await SessionStore.shared.process(.hookReceived(event))
                }

                if event.sessionPhase == .processing {
                    Task { @MainActor in
                        InterruptWatcherManager.shared.startWatching(
                            sessionId: event.sessionId,
                            cwd: event.cwd
                        )
                    }
                }

                if event.status == "ended" {
                    Task { @MainActor in
                        InterruptWatcherManager.shared.stopWatching(sessionId: event.sessionId)
                    }
                }

                if event.event == "Stop" {
                    HookSocketServer.shared.cancelPendingPermissions(sessionId: event.sessionId)
                }

                if event.event == "PostToolUse", let toolUseId = event.toolUseId {
                    HookSocketServer.shared.cancelPendingPermission(toolUseId: toolUseId)
                }
            },
            onPermissionFailure: { sessionId, toolUseId in
                Task {
                    await SessionStore.shared.process(
                        .permissionSocketFailed(sessionId: sessionId, toolUseId: toolUseId)
                    )
                }
            }
        )
    }

    func stopMonitoring() {
        HookSocketServer.shared.stop()
        codexRefreshTimer?.invalidate()
        codexRefreshTimer = nil
    }

    // MARK: - Permission Handling

    func approvePermission(sessionId: String) {
        Task {
            guard let session = await SessionStore.shared.session(for: sessionId),
                  let permission = session.activePermission else {
                return
            }

            HookSocketServer.shared.respondToPermission(
                toolUseId: permission.toolUseId,
                decision: "allow"
            )

            await SessionStore.shared.process(
                .permissionApproved(sessionId: sessionId, toolUseId: permission.toolUseId)
            )
        }
    }

    func denyPermission(sessionId: String, reason: String?) {
        Task {
            guard let session = await SessionStore.shared.session(for: sessionId),
                  let permission = session.activePermission else {
                return
            }

            HookSocketServer.shared.respondToPermission(
                toolUseId: permission.toolUseId,
                decision: "deny",
                reason: reason
            )

            await SessionStore.shared.process(
                .permissionDenied(sessionId: sessionId, toolUseId: permission.toolUseId, reason: reason)
            )
        }
    }

    /// Archive (remove) a session from the instances list
    func archiveSession(sessionId: String) {
        Task {
            await SessionStore.shared.process(.sessionEnded(sessionId: sessionId))
        }
    }

    // MARK: - State Update

    private func updateFromSessions(_ sessions: [SessionState]) {
        instances = sessions
        pendingInstances = sessions.filter { $0.needsAttention }
    }

    private func startCodexRefreshTimer() {
        guard codexRefreshTimer == nil else { return }

        codexRefreshTimer = Timer.scheduledTimer(withTimeInterval: codexRefreshInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.refreshCodexSessions()
                await self.pruneStaleCodexSessions()
            }
        }
    }

    private func refreshCodexSessions() async {
        let activeProcesses = ProcessTreeBuilder.shared.activeCodexProcessesBySessionId()
        let discoveredCodexSessions = await CodexSessionScanner.shared.scanRecentSessions()

        let sessionsToRefresh = discoveredCodexSessions.compactMap { session -> SessionState? in
            guard let activeProcess = activeProcesses[session.sessionId] else {
                return nil
            }

            return SessionState(
                sessionId: session.sessionId,
                cwd: session.cwd,
                projectName: session.projectName,
                provider: session.provider,
                pid: activeProcess.pid,
                tty: activeProcess.tty,
                isInTmux: activeProcess.isInTmux,
                phase: session.phase,
                chatItems: session.chatItems,
                toolTracker: session.toolTracker,
                subagentState: session.subagentState,
                conversationInfo: session.conversationInfo,
                needsClearReconciliation: session.needsClearReconciliation,
                lastActivity: session.lastActivity,
                createdAt: session.createdAt
            )
        }

        for session in sessionsToRefresh {
            await SessionStore.shared.process(.sessionDiscovered(session))
            await SessionStore.shared.process(.loadHistory(sessionId: session.sessionId, cwd: session.cwd))
        }
    }

    private func pruneStaleCodexSessions() async {
        let codexInstances = instances.filter { $0.provider == .codex }
        guard !codexInstances.isEmpty else { return }

        let activeSessionIds = ProcessTreeBuilder.shared.activeCodexSessionIds()
        if !activeSessionIds.isEmpty {
            let staleSessionIds = codexInstances
                .filter { !activeSessionIds.contains($0.sessionId) }
                .map(\.sessionId)

            for sessionId in staleSessionIds {
                await SessionStore.shared.process(.sessionEnded(sessionId: sessionId))
            }
            return
        }

        let activeCounts = ProcessTreeBuilder.shared.activeCodexProcessCountsByWorkingDirectory()
        let grouped = Dictionary(grouping: codexInstances, by: \.cwd)

        var staleSessionIds: [String] = []

        for (cwd, sessionsForCwd) in grouped {
            let keepCount = activeCounts[cwd] ?? 0
            let sorted = sessionsForCwd.sorted { lhs, rhs in
                if lhs.lastActivity != rhs.lastActivity {
                    return lhs.lastActivity > rhs.lastActivity
                }
                return lhs.createdAt > rhs.createdAt
            }

            if keepCount <= 0 {
                staleSessionIds.append(contentsOf: sorted.map(\.sessionId))
            } else if sorted.count > keepCount {
                staleSessionIds.append(contentsOf: sorted.dropFirst(keepCount).map(\.sessionId))
            }
        }

        for sessionId in staleSessionIds {
            await SessionStore.shared.process(.sessionEnded(sessionId: sessionId))
        }
    }

    // MARK: - History Loading (for UI)

    /// Request history load for a session
    func loadHistory(sessionId: String, cwd: String) {
        Task {
            await SessionStore.shared.process(.loadHistory(sessionId: sessionId, cwd: cwd))
        }
    }
}

// MARK: - Interrupt Watcher Delegate

extension SessionMonitor: JSONLInterruptWatcherDelegate {
    nonisolated func didDetectInterrupt(sessionId: String) {
        Task {
            await SessionStore.shared.process(.interruptDetected(sessionId: sessionId))
        }

        Task { @MainActor in
            InterruptWatcherManager.shared.stopWatching(sessionId: sessionId)
        }
    }
}

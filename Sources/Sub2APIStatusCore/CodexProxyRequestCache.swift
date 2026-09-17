import Foundation

/// Collapses the repeated calls one refresh makes into a single request each.
///
/// `MonitorViewModel` fans out across every `DataProvider` method concurrently,
/// and three of them independently need the user profile. Storing the in-flight
/// `Task` rather than its result is what makes the collapsing work: concurrent
/// callers arrive before the first response lands, so a value cache would still
/// be empty and each would issue its own request.
///
/// The cache lives as long as the provider instance, which is rebuilt on every
/// refresh, so there is no expiry to reason about and a failure never leaks into
/// the next cycle.
actor CodexProxyRequestCache {
    private let client: CodexProxyClient
    private let now: @Sendable () -> Date

    private var profileTask: Task<CodexProxyUserProfile, Error>?
    private var requestUsageTask: Task<[CodexProxyRequestUsage], Error>?
    private var summaryTasks: [String: Task<CodexProxyUsageSummary, Error>] = [:]
    private var overviewTasks: [String: Task<CodexProxyUsageOverview, Error>] = [:]
    private var diagnosticsTasks: [String: Task<CodexProxyDiagnosticsResponse, Error>] = [:]
    private var realtimeWindow: (start: Date, end: Date)?

    init(client: CodexProxyClient, now: @escaping @Sendable () -> Date = { Date() }) {
        self.client = client
        self.now = now
    }

    func profile() async throws -> CodexProxyUserProfile {
        if let profileTask {
            return try await profileTask.value
        }
        let task = Task { [client] in try await client.userProfile() }
        profileTask = task
        return try await task.value
    }

    func requestUsage() async throws -> [CodexProxyRequestUsage] {
        if let requestUsageTask {
            return try await requestUsageTask.value
        }
        let task = Task { [client] in try await client.requestUsage() }
        requestUsageTask = task
        return try await task.value
    }

    func summary(startTime: Date, endTime: Date) async throws -> CodexProxyUsageSummary {
        let key = Self.windowKey(startTime, endTime)
        if let existing = summaryTasks[key] {
            return try await existing.value
        }
        let task = Task { [client] in
            try await client.usageSummary(startTime: startTime, endTime: endTime)
        }
        summaryTasks[key] = task
        return try await task.value
    }

    func overview(startTime: Date, endTime: Date) async throws -> CodexProxyUsageOverview {
        let key = Self.windowKey(startTime, endTime)
        if let existing = overviewTasks[key] {
            return try await existing.value
        }
        let task = Task { [client] in
            try await client.usageOverview(startTime: startTime, endTime: endTime)
        }
        overviewTasks[key] = task
        return try await task.value
    }

    /// The overview window used for latency and error rate. The boundaries are
    /// pinned on first use because two callers computing `Date()` milliseconds
    /// apart would produce different cache keys and duplicate the request.
    func realtimeOverview() async throws -> CodexProxyUsageOverview {
        let window = realtimeWindow ?? CodexProxyDate.realtimeWindow(now: now())
        realtimeWindow = window
        return try await overview(startTime: window.start, endTime: window.end)
    }

    func diagnostics(
        startTime: Date,
        endTime: Date,
        dimension: String
    ) async throws -> CodexProxyDiagnosticsResponse {
        let key = "\(dimension)|\(Self.windowKey(startTime, endTime))"
        if let existing = diagnosticsTasks[key] {
            return try await existing.value
        }
        let task = Task { [client] in
            try await client.usageDiagnostics(startTime: startTime, endTime: endTime, dimension: dimension)
        }
        diagnosticsTasks[key] = task
        return try await task.value
    }

    private static func windowKey(_ start: Date, _ end: Date) -> String {
        "\(start.timeIntervalSince1970)-\(end.timeIntervalSince1970)"
    }
}

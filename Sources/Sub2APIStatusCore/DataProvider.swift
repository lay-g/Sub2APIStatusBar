import Foundation

/// Unified protocol for fetching monitoring data from different API providers
public protocol DataProvider: Sendable {
    /// Fetch current user information
    func fetchCurrentUser() async throws -> CurrentUser?

    /// Fetch subscription summary (quota information)
    func fetchSubscriptionSummary() async throws -> SubscriptionSummary

    /// Fetch dashboard statistics
    func fetchDashboardStats() async throws -> DashboardStats

    /// Fetch usage trend
    func fetchUsageTrend(startDate: String, endDate: String, granularity: String) async throws -> DashboardTrendResponse

    /// Fetch model usage distribution
    func fetchModelUsage(startDate: String, endDate: String) async throws -> DashboardModelsResponse

    /// Fetch real-time metrics
    func fetchRealtimeMetrics() async throws -> RealtimeMetrics?

    /// Fetch account health summary
    func fetchAccountHealth() async throws -> AccountHealthSummary?
}

// MARK: - Sub2API Provider

public struct Sub2APIDataProvider: DataProvider {
    private let client: Sub2APIClient

    public init(config: AppConfig, session: URLSession = .shared) {
        self.client = Sub2APIClient(config: config, session: session)
    }

    public func fetchCurrentUser() async throws -> CurrentUser? {
        try await client.currentUser().user
    }

    public func fetchSubscriptionSummary() async throws -> SubscriptionSummary {
        try await client.subscriptionSummary()
    }

    public func fetchDashboardStats() async throws -> DashboardStats {
        try await client.usageDashboardStats()
    }

    public func fetchUsageTrend(startDate: String, endDate: String, granularity: String) async throws -> DashboardTrendResponse {
        try await client.usageDashboardTrend(startDate: startDate, endDate: endDate, granularity: granularity)
    }

    public func fetchModelUsage(startDate: String, endDate: String) async throws -> DashboardModelsResponse {
        try await client.usageDashboardModels(startDate: startDate, endDate: endDate)
    }

    public func fetchRealtimeMetrics() async throws -> RealtimeMetrics? {
        // Sub2API doesn't have a dedicated realtime endpoint
        // Return nil or implement if available
        nil
    }

    public func fetchAccountHealth() async throws -> AccountHealthSummary? {
        // Sub2API doesn't expose account health in user mode
        nil
    }
}

// MARK: - CodexProxy Provider

public struct CodexProxyDataProvider: DataProvider {
    private let cache: CodexProxyRequestCache
    private let now: @Sendable () -> Date

    public init(
        config: AppConfig,
        session: URLSession = CodexProxyClient.defaultSession,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.cache = CodexProxyRequestCache(
            client: CodexProxyClient(config: config, session: session),
            now: now
        )
        self.now = now
    }

    public func fetchCurrentUser() async throws -> CurrentUser? {
        let profile = try await cache.profile()
        return CodexProxyAdapters.toCurrentUser(profile)
    }

    public func fetchSubscriptionSummary() async throws -> SubscriptionSummary {
        let profile = try await cache.profile()
        return CodexProxyAdapters.toSubscriptionSummary(profile)
    }

    public func fetchDashboardStats() async throws -> DashboardStats {
        // One instant shared by both windows so their end boundaries match.
        let instant = now()
        let today = CodexProxyDate.todayWindow(now: instant)
        let month = CodexProxyDate.monthToDateWindow(now: instant)

        async let profileTask = cache.profile()
        async let todayTask = cache.summary(startTime: today.start, endTime: today.end)
        async let monthTask = cache.summary(startTime: month.start, endTime: month.end)
        async let realtimeUsageTask = cache.requestUsage()
        async let overviewTask = cache.realtimeOverview()

        let profile = try await profileTask
        return CodexProxyAdapters.toDashboardStats(
            todaySummary: try await todayTask,
            monthSummary: try await monthTask,
            profile: profile,
            realtimeUsage: (try? await realtimeUsageTask)?.entry(for: profile.id),
            realtimeOverview: try? await overviewTask
        )
    }

    public func fetchUsageTrend(startDate: String, endDate: String, granularity: String) async throws -> DashboardTrendResponse {
        guard let range = CodexProxyDate.rangeBoundaries(start: startDate, end: endDate) else {
            throw CodexProxyError.invalidDateRange(startDate, endDate)
        }

        let overview = try await cache.overview(startTime: range.start, endTime: range.end)

        return DashboardTrendResponse(
            startDate: startDate,
            endDate: endDate,
            granularity: granularity,
            trend: CodexProxyAdapters.toTrendDataPoints(overview)
        )
    }

    public func fetchModelUsage(startDate: String, endDate: String) async throws -> DashboardModelsResponse {
        guard let range = CodexProxyDate.rangeBoundaries(start: startDate, end: endDate) else {
            throw CodexProxyError.invalidDateRange(startDate, endDate)
        }

        let diagnostics = try await cache.diagnostics(
            startTime: range.start,
            endTime: range.end,
            dimension: "model"
        )

        return DashboardModelsResponse(
            startDate: startDate,
            endDate: endDate,
            models: CodexProxyAdapters.toModelUsageSummaries(diagnostics.items)
        )
    }

    public func fetchRealtimeMetrics() async throws -> RealtimeMetrics? {
        let usage = try await cache.requestUsage()
        let overview = try? await cache.realtimeOverview()

        return CodexProxyAdapters.toRealtimeMetrics(
            requestUsage: usage.entry(for: (try? await cache.profile())?.id),
            overview: overview
        )
    }

    public func fetchAccountHealth() async throws -> AccountHealthSummary? {
        // Upstream account health is admin-only in codex-proxy-rs
        nil
    }
}

// MARK: - Provider Factory

public enum DataProviderFactory {
    public static func create(config: AppConfig, session: URLSession? = nil) -> DataProvider {
        switch config.provider {
        case .sub2api:
            return Sub2APIDataProvider(config: config, session: session ?? .shared)
        case .codexProxy:
            return CodexProxyDataProvider(config: config, session: session ?? CodexProxyClient.defaultSession)
        }
    }
}

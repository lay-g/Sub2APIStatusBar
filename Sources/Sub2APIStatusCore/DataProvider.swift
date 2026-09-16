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

    /// Refresh authentication token
    func refreshAuthToken(_ refreshToken: String) async throws -> AuthResponse
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

    public func refreshAuthToken(_ refreshToken: String) async throws -> AuthResponse {
        try await client.refreshToken(refreshToken)
    }
}

// MARK: - CodexProxy Provider

public struct CodexProxyDataProvider: DataProvider {
    private let client: CodexProxyClient
    private var cachedProfile: CodexProxyUserProfile?

    public init(config: AppConfig, session: URLSession = .shared) {
        self.client = CodexProxyClient(config: config, session: session)
    }

    public func fetchCurrentUser() async throws -> CurrentUser? {
        let profile = try await client.userProfile()
        return CodexProxyAdapters.toCurrentUser(profile)
    }

    public func fetchSubscriptionSummary() async throws -> SubscriptionSummary {
        let profile = try await client.userProfile()
        return CodexProxyAdapters.toSubscriptionSummary(profile)
    }

    public func fetchDashboardStats() async throws -> DashboardStats {
        let profile = try await client.userProfile()
        let endDate = Date()
        let startDate = Calendar.current.date(byAdding: .day, value: -1, to: endDate) ?? endDate

        let summary = try await client.usageSummary(startTime: startDate, endTime: endDate)
        let realtimeUsage = try? await client.requestUsage()

        return CodexProxyAdapters.toDashboardStats(
            summary: summary,
            profile: profile,
            realtimeUsage: realtimeUsage
        )
    }

    public func fetchUsageTrend(startDate: String, endDate: String, granularity: String) async throws -> DashboardTrendResponse {
        let formatter = ISO8601DateFormatter()
        guard let start = formatter.date(from: startDate),
              let end = formatter.date(from: endDate) else {
            throw CodexProxyError.invalidBaseURL
        }

        let overview = try await client.usageOverview(startTime: start, endTime: end)
        let trendPoints = CodexProxyAdapters.toTrendDataPoints(overview.trend)

        return DashboardTrendResponse(
            startDate: startDate,
            endDate: endDate,
            granularity: granularity,
            trend: trendPoints
        )
    }

    public func fetchModelUsage(startDate: String, endDate: String) async throws -> DashboardModelsResponse {
        let formatter = ISO8601DateFormatter()
        guard let start = formatter.date(from: startDate),
              let end = formatter.date(from: endDate) else {
            throw CodexProxyError.invalidBaseURL
        }

        let records = try await client.usageRecords(
            startTime: start,
            endTime: end,
            currentPage: 1,
            pageSize: 1000  // Fetch more records for aggregation
        )

        let models = CodexProxyAdapters.toModelUsageSummaries(records.items)

        return DashboardModelsResponse(
            startDate: startDate,
            endDate: endDate,
            models: models
        )
    }

    public func fetchRealtimeMetrics() async throws -> RealtimeMetrics? {
        let requestUsage = try await client.requestUsage()

        // Get recent trend for average response time calculation
        let endDate = Date()
        let startDate = Calendar.current.date(byAdding: .hour, value: -1, to: endDate) ?? endDate
        let overview = try? await client.usageOverview(startTime: startDate, endTime: endDate)

        return CodexProxyAdapters.toRealtimeMetrics(
            requestUsage: requestUsage,
            trend: overview?.trend ?? []
        )
    }

    public func fetchAccountHealth() async throws -> AccountHealthSummary? {
        // CodexProxy doesn't expose account health to regular users
        nil
    }

    public func refreshAuthToken(_ refreshToken: String) async throws -> AuthResponse {
        // CodexProxy uses session cookies, not refresh tokens
        // This should trigger a re-login instead
        throw CodexProxyError.api(code: 401, message: "Session expired, please login again")
    }
}

// MARK: - Provider Factory

public enum DataProviderFactory {
    public static func create(config: AppConfig, session: URLSession = .shared) -> DataProvider {
        switch config.provider {
        case .sub2api:
            return Sub2APIDataProvider(config: config, session: session)
        case .codexProxy:
            return CodexProxyDataProvider(config: config, session: session)
        }
    }
}

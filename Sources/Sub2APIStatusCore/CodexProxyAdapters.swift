import Foundation

// MARK: - CodexProxy to Sub2API Adapters

public enum CodexProxyAdapters {
    // MARK: - User Profile to CurrentUser

    public static func toCurrentUser(_ profile: CodexProxyUserProfile) -> CurrentUser {
        CurrentUser(
            id: Int64(profile.id.hashValue),  // Convert string ID to Int64
            email: profile.username,
            username: profile.username,
            role: profile.role,
            balance: nil,  // CodexProxy doesn't have balance concept
            status: profile.enabled ? "active" : "disabled"
        )
    }

    // MARK: - User Profile to SubscriptionSummary

    public static func toSubscriptionSummary(_ profile: CodexProxyUserProfile) -> SubscriptionSummary {
        // Create a single subscription item from user profile
        let subscriptionItem = SubscriptionSummaryItem(
            id: Int64(profile.id.hashValue),
            groupName: profile.groups.first?.name ?? "Default",
            status: profile.enabled ? "active" : "disabled",
            dailyUsedUSD: profile.dailyUsed,
            dailyLimitUSD: profile.dailyLimit > 0 ? profile.dailyLimit : nil,
            weeklyUsedUSD: profile.weeklyUsed,
            weeklyLimitUSD: profile.weeklyLimit > 0 ? profile.weeklyLimit : nil,
            monthlyUsedUSD: nil,  // CodexProxy doesn't support monthly quota
            monthlyLimitUSD: nil,
            dailyResetInSeconds: calculateResetSeconds(from: profile.dailyResetsAt),
            weeklyResetInSeconds: calculateResetSeconds(from: profile.weeklyResetsAt),
            monthlyResetInSeconds: nil,
            dailyProgress: profile.dailyProgress,
            weeklyProgress: profile.weeklyProgress,
            monthlyProgress: nil,
            expiresAt: nil,
            daysRemaining: nil
        )

        return SubscriptionSummary(
            activeCount: profile.enabled ? 1 : 0,
            totalUsedUSD: profile.dailyUsed + profile.weeklyUsed,
            subscriptions: [subscriptionItem]
        )
    }

    // MARK: - Usage Summary to DashboardStats

    public static func toDashboardStats(
        summary: CodexProxyUsageSummary,
        profile: CodexProxyUserProfile,
        realtimeUsage: CodexProxyRequestUsage?
    ) -> DashboardStats {
        DashboardStats(
            totalUsers: 1,  // CodexProxy doesn't expose total users
            activeUsers: profile.enabled ? 1 : 0,
            totalAPIKeys: profile.keyCount,
            activeAPIKeys: profile.keyCount,
            totalAccounts: 0,  // CodexProxy doesn't expose accounts to users
            normalAccounts: 0,
            errorAccounts: 0,
            ratelimitAccounts: 0,
            overloadAccounts: 0,
            totalRequests: Int64(summary.requests),
            totalTokens: Int64(summary.totalTokens),
            totalInputTokens: Int64(summary.inputTokens),
            totalOutputTokens: Int64(summary.outputTokens),
            totalCacheCreationTokens: Int64(summary.cacheWriteTokens),
            totalCacheReadTokens: Int64(summary.cachedTokens),
            totalCost: summary.cost,
            totalActualCost: summary.cost,
            todayRequests: Int64(summary.requests),  // Approximate
            todayTokens: Int64(summary.totalTokens),
            todayInputTokens: Int64(summary.inputTokens),
            todayOutputTokens: Int64(summary.outputTokens),
            todayCacheCreationTokens: Int64(summary.cacheWriteTokens),
            todayCacheReadTokens: Int64(summary.cachedTokens),
            todayCost: summary.cost,
            todayActualCost: summary.cost,
            averageDurationMs: 0,  // Not available in summary
            uptime: 0,  // Not available
            rpm: Double(realtimeUsage?.currentRpm ?? 0),
            tpm: 0  // Calculate from trend if needed
        )
    }

    // MARK: - Trend Points to TrendDataPoint

    public static func toTrendDataPoints(_ trend: [CodexProxyTrendPoint]) -> [TrendDataPoint] {
        trend.map { point in
            TrendDataPoint(
                date: point.time,
                requests: Int64(point.requests),
                inputTokens: Int64(point.inputTokens),
                outputTokens: Int64(point.outputTokens),
                cacheCreationTokens: Int64(point.cacheWriteTokens),
                cacheReadTokens: Int64(point.cachedTokens),
                totalTokens: Int64(point.totalTokens),
                cost: point.cost,
                actualCost: point.cost
            )
        }
    }

    // MARK: - Usage Records to ModelUsageSummary

    public static func toModelUsageSummaries(_ records: [CodexProxyUsageRecord]) -> [ModelUsageSummary] {
        // Group records by model
        let grouped = Dictionary(grouping: records) { $0.model ?? "Unknown" }

        return grouped.map { model, records in
            let totalRequests = records.count
            let totalInputTokens = records.reduce(0) { $0 + ($1.tokenDetails?.inputTokens ?? 0) }
            let totalOutputTokens = records.reduce(0) { $0 + ($1.tokenDetails?.outputTokens ?? 0) }
            let totalCacheReadTokens = records.reduce(0) { $0 + ($1.tokenDetails?.cachedTokens ?? 0) }
            let totalCacheWriteTokens = records.reduce(0) { $0 + ($1.tokenDetails?.cacheWriteTokens ?? 0) }
            let totalTokens = records.reduce(0) { $0 + ($1.tokenDetails?.totalTokens ?? 0) }
            let totalCost = records.reduce(0.0) { $0 + ($1.billing?.cost ?? 0) }
            let totalActualCost = records.reduce(0.0) { $0 + ($1.billing?.actualCost ?? 0) }

            return ModelUsageSummary(
                model: model,
                requests: Int64(totalRequests),
                totalTokens: Int64(totalTokens),
                inputTokens: Int64(totalInputTokens),
                outputTokens: Int64(totalOutputTokens),
                cacheCreationTokens: Int64(totalCacheWriteTokens),
                cacheReadTokens: Int64(totalCacheReadTokens),
                cost: totalCost,
                actualCost: totalActualCost,
                accountCost: totalActualCost,  // Use actualCost as accountCost
                standardCost: totalCost  // Use cost as standardCost
            )
        }.sorted { $0.totalTokens > $1.totalTokens }  // Sort by token usage
    }

    // MARK: - Request Usage to RealtimeMetrics

    public static func toRealtimeMetrics(
        requestUsage: CodexProxyRequestUsage,
        trend: [CodexProxyTrendPoint]
    ) -> RealtimeMetrics {
        // Calculate average response time from recent trend
        let recentPoints = trend.suffix(10)  // Last 10 data points
        let avgResponseTime = recentPoints.isEmpty ? 0 : Double(recentPoints.reduce(0) { $0 + $1.bucketSeconds }) / Double(recentPoints.count)

        return RealtimeMetrics(
            activeRequests: requestUsage.currentConcurrency ?? 0,
            requestsPerMinute: Double(requestUsage.currentRpm ?? 0),
            averageResponseTime: avgResponseTime,
            errorRate: 0
        )
    }

    // MARK: - Helper Functions

    private static func calculateResetSeconds(from resetTimeString: String) -> Double? {
        let formatter = ISO8601DateFormatter()
        guard let resetDate = formatter.date(from: resetTimeString) else {
            return nil
        }
        let seconds = resetDate.timeIntervalSinceNow
        return seconds > 0 ? seconds : nil
    }
}

// MARK: - CodexProxy Client Keys to Account Summary

public extension CodexProxyAdapters {
    static func toAccountSummaries(_ keys: [CodexProxyClientKey]) -> [AccountSummary] {
        keys.map { key in
            AccountSummary(
                id: Int64(key.id.hashValue),
                name: key.name,
                platform: "codex-proxy",
                type: "client_key",
                status: key.enabled ? "active" : "disabled",
                schedulable: key.enabled,
                quotaLimit: Double(key.dailyLimitUsd),
                quotaUsed: 0,  // Not available in key list
                quotaDailyLimit: Double(key.dailyLimitUsd),
                quotaDailyUsed: 0,
                quotaWeeklyLimit: Double(key.weeklyLimitUsd),
                quotaWeeklyUsed: 0,
                errorMessage: "",
                rateLimitResetAt: nil
            )
        }
    }

    static func toAccountHealthSummary(_ keys: [CodexProxyClientKey]) -> AccountHealthSummary {
        let accounts = toAccountSummaries(keys)
        return AccountHealthSummary(accounts: accounts)
    }
}

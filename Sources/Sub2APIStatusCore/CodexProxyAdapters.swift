import Foundation

// MARK: - CodexProxy to Sub2API Adapters

public enum CodexProxyAdapters {
    /// codex-proxy-rs identifies everything by string (`me@lay-g.com`,
    /// `key_01a09...`), while the snapshot models use Int64. Swift's `hashValue`
    /// is seeded per process, so IDs would change on every launch; FNV-1a keeps
    /// them stable.
    public static func stableID(_ value: String) -> Int64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return Int64(bitPattern: hash)
    }

    // MARK: - User Profile to CurrentUser

    public static func toCurrentUser(_ profile: CodexProxyUserProfile) -> CurrentUser {
        CurrentUser(
            id: stableID(profile.id),
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
            id: stableID(profile.id),
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

    /// `todaySummary` covers local midnight to now; `monthSummary` covers the
    /// first of the month to now. codex-proxy-rs has no monthly quota, so "total"
    /// here means month-to-date by product decision. Latency and TPM come from the
    /// shared trailing-hour overview so they cost no extra request.
    public static func toDashboardStats(
        todaySummary: CodexProxyUsageSummary,
        monthSummary: CodexProxyUsageSummary,
        profile: CodexProxyUserProfile,
        realtimeUsage: CodexProxyRequestUsage?,
        realtimeOverview: CodexProxyUsageOverview?
    ) -> DashboardStats {
        let rpm = Double(realtimeUsage?.currentRpm ?? 0)
        return DashboardStats(
            totalUsers: 1,  // CodexProxy doesn't expose total users
            activeUsers: profile.enabled ? 1 : 0,
            totalAPIKeys: profile.keyCount,
            activeAPIKeys: profile.keyCount,
            totalAccounts: 0,  // CodexProxy doesn't expose accounts to users
            normalAccounts: 0,
            errorAccounts: 0,
            ratelimitAccounts: 0,
            overloadAccounts: 0,
            totalRequests: Int64(monthSummary.requests),
            totalTokens: Int64(monthSummary.totalTokens),
            totalInputTokens: Int64(monthSummary.inputTokens),
            totalOutputTokens: Int64(monthSummary.outputTokens),
            totalCacheCreationTokens: Int64(monthSummary.cacheWriteTokens),
            totalCacheReadTokens: Int64(monthSummary.cachedTokens),
            totalCost: monthSummary.cost,
            totalActualCost: monthSummary.cost,
            todayRequests: Int64(todaySummary.requests),
            todayTokens: Int64(todaySummary.totalTokens),
            todayInputTokens: Int64(todaySummary.inputTokens),
            todayOutputTokens: Int64(todaySummary.outputTokens),
            todayCacheCreationTokens: Int64(todaySummary.cacheWriteTokens),
            todayCacheReadTokens: Int64(todaySummary.cachedTokens),
            todayCost: todaySummary.cost,
            todayActualCost: todaySummary.cost,
            averageDurationMs: realtimeOverview?.averageLatencyMs ?? 0,  // P50 over the trailing hour
            uptime: 0,  // Not available
            rpm: rpm,
            tpm: (realtimeOverview?.tokensPerRequest ?? 0) * rpm
        )
    }

    // MARK: - Overview to TrendDataPoint

    /// The overview splits its series across `health.points` (requests) and
    /// `cost.points` (tokens and money); `trendPoints` merges them by bucket.
    public static func toTrendDataPoints(_ overview: CodexProxyUsageOverview) -> [TrendDataPoint] {
        overview.trendPoints.map { point in
            TrendDataPoint(
                date: point.bucket,
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

    // MARK: - Diagnostics to ModelUsageSummary

    /// Diagnostics reports a combined token count only; codex-proxy-rs exposes no
    /// per-model input/output split, so those stay zero and the mix line is omitted.
    /// Recovering the split would require paging /usage/records, deliberately
    /// dropped for request-budget reasons (docs/plans/codex-proxy-request-budget.md).
    public static func toModelUsageSummaries(_ items: [CodexProxyDiagnosticsItem]) -> [ModelUsageSummary] {
        items
            .map { item in
                ModelUsageSummary(
                    model: item.name.isEmpty ? item.key : item.name,
                    requests: Int64(item.requestCount),
                    totalTokens: Int64(item.totalTokens),
                    inputTokens: 0,
                    outputTokens: 0,
                    cacheCreationTokens: 0,
                    cacheReadTokens: 0,
                    cost: item.cost,
                    actualCost: item.cost,
                    accountCost: item.cost,
                    standardCost: item.cost
                )
            }
            .sorted { $0.totalTokens > $1.totalTokens }
    }

    // MARK: - Request Usage to RealtimeMetrics

    public static func toRealtimeMetrics(
        requestUsage: CodexProxyRequestUsage,
        overview: CodexProxyUsageOverview?
    ) -> RealtimeMetrics {
        RealtimeMetrics(
            activeRequests: requestUsage.currentConcurrency,
            requestsPerMinute: Double(requestUsage.currentRpm),
            averageResponseTime: overview?.averageLatencyMs ?? 0,
            errorRate: overview?.errorRate ?? 0
        )
    }

    // MARK: - Helper Functions

    private static func calculateResetSeconds(from resetTimeString: String) -> Double? {
        guard let resetDate = CodexProxyDate.parse(resetTimeString) else {
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
                id: stableID(key.id),
                name: key.name,
                platform: "codex-proxy",
                type: "client_key",
                status: key.enabled ? "active" : "disabled",
                schedulable: key.enabled,
                quotaLimit: key.dailyLimit,
                quotaUsed: key.dailyUsed,
                quotaDailyLimit: key.dailyLimit,
                quotaDailyUsed: key.dailyUsed,
                quotaWeeklyLimit: key.weeklyLimit,
                quotaWeeklyUsed: key.weeklyUsed,
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

// MARK: - Date Parsing

enum CodexProxyDate {
    /// codex-proxy-rs mixes RFC3339 with and without fractional seconds
    /// (`2026-09-17T16:00:00Z`, `2026-09-13T23:16:10.870531Z`,
    /// `2026-09-18T00:40:52.501387403+00:00`), and the dashboard passes plain
    /// `yyyy-MM-dd` range boundaries.
    static func parse(_ value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let iso8601 = ISO8601DateFormatter()
        if let date = iso8601.date(from: trimmed) {
            return date
        }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: trimmed) {
            return date
        }

        // The dashboard formats these from local dates, so parse them back in the
        // local timezone to keep the range symmetric.
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.calendar = Calendar(identifier: .gregorian)
        day.dateFormat = "yyyy-MM-dd"
        return day.date(from: trimmed)
    }

    /// Expands a `yyyy-MM-dd` boundary into a concrete instant, clamping the end
    /// of the range to the last second of that day.
    static func rangeBoundaries(start: String, end: String) -> (start: Date, end: Date)? {
        guard let startDate = parse(start) else { return nil }
        guard let endDate = parse(end) else { return nil }

        let calendar = Calendar(identifier: .gregorian)
        let normalizedStart = calendar.startOfDay(for: startDate)
        let normalizedEnd = calendar.date(
            byAdding: DateComponents(day: 1, second: -1),
            to: calendar.startOfDay(for: endDate)
        ) ?? endDate

        return (normalizedStart, normalizedEnd)
    }

    /// Local midnight to now. The server resets daily quota at Beijing midnight,
    /// which matches the local day for this app's users.
    static func todayWindow(now: Date = Date(), calendar: Calendar = .current) -> (start: Date, end: Date) {
        (calendar.startOfDay(for: now), now)
    }

    /// First day of the current month to now. codex-proxy-rs has no monthly quota,
    /// so this is purely the reporting window chosen for the "total" figures.
    static func monthToDateWindow(now: Date = Date(), calendar: Calendar = .current) -> (start: Date, end: Date) {
        let components = calendar.dateComponents([.year, .month], from: now)
        let start = calendar.date(from: components) ?? calendar.startOfDay(for: now)
        return (start, now)
    }

    /// The trailing hour used for latency and error-rate figures.
    static func realtimeWindow(now: Date = Date(), calendar: Calendar = .current) -> (start: Date, end: Date) {
        (calendar.date(byAdding: .hour, value: -1, to: now) ?? now, now)
    }
}

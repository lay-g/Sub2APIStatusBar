import Foundation
import Testing
@testable import Sub2APIStatusCore

// Verifies the per-refresh HTTP request budget for the codexProxy provider.
//
// These tests replicate the concurrent fan-out that MonitorViewModel.userSnapshot
// performs (it lives in the executable target and cannot be imported here). If
// that method's set of DataProvider calls changes, update exerciseFullRefresh.
//
// The suite is serialized because the stub URLProtocol counts requests through
// shared static state, which parallel tests would interleave.

private final class PathCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    func record(_ path: String) {
        lock.lock(); defer { lock.unlock() }
        counts[path, default: 0] += 1
    }

    func count(_ path: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return counts[path] ?? 0
    }

    var total: Int {
        lock.lock(); defer { lock.unlock() }
        return counts.values.reduce(0, +)
    }
}

private final class CounterBox: @unchecked Sendable {
    private let lock = NSLock()
    private var counter = PathCounter()

    func swap() -> PathCounter {
        lock.lock(); defer { lock.unlock() }
        let fresh = PathCounter()
        counter = fresh
        return fresh
    }

    var current: PathCounter {
        lock.lock(); defer { lock.unlock() }
        return counter
    }
}

private let counterBox = CounterBox()

private final class StubURLProtocol: URLProtocol {
    static func reset() -> PathCounter { counterBox.swap() }

    static func fixture(for path: String) -> String {
        switch path {
        case "/api/user/profile":
            return #"{"code":200,"message":"OK","data":{"id":"user@example.com","username":"user@example.com","role":"user","enabled":true,"keyCount":2,"maxConcurrency":0,"requestsPerMinute":0,"dailyLimitUsd":"300","weeklyLimitUsd":"1000","dailyUsedUsd":"0","weeklyUsedUsd":"0","dailyResetsAt":"2026-09-17T16:00:00Z","weeklyResetsAt":"2026-09-20T16:00:00Z"}}"#
        case "/api/user/request-usage":
            return #"{"code":200,"message":"OK","data":[{"id":"user@example.com","currentConcurrency":3,"currentRpm":7}]}"#
        case "/api/user/usage/records/summary":
            return #"{"code":200,"message":"OK","data":{"logicalRequests":{"requestCount":10,"successCount":10,"failureCount":0,"inputTokens":100,"outputTokens":50,"cachedTokens":0,"cacheWriteTokens":0,"reasoningTokens":0,"totalTokens":150},"attempts":{"attemptCount":10,"successCount":10,"failureCount":0,"costs":[{"currency":"USD","estimatedAmount":"1.23"}]}}}"#
        case "/api/user/usage/insights/overview":
            return overviewJSON
        case "/api/user/usage/insights/diagnostics":
            return #"{"code":200,"message":"OK","data":{"dimension":"model","items":[]}}"#
        default:
            return #"{"code":200,"message":"OK","data":null}"#
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        counterBox.current.record(path)

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.fixture(for: path).utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func stubbedSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpShouldSetCookies = false
    configuration.httpCookieAcceptPolicy = .never
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: configuration)
}

private func fixedClock(day: Int) -> @Sendable () -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    let date = calendar.date(from: DateComponents(
        year: 2026, month: 9, day: day, hour: 15, minute: 30
    ))!
    return { date }
}

private func stubbedConfig() -> AppConfig {
    var config = AppConfig(provider: .codexProxy, baseURL: "https://example.com")
    config.upsertAccount(
        name: "user@example.com",
        email: "user@example.com",
        baseURL: "https://example.com",
        tokens: StoredAuthTokens(authToken: "session_abc")
    )
    config.normalize()
    return config
}

/// Fires every DataProvider method concurrently, mirroring userSnapshot. This is
/// the worst case for deduplication: the three profile callers race each other.
private func exerciseFullRefresh(_ provider: CodexProxyDataProvider) async throws {
    async let currentUser = provider.fetchCurrentUser()
    async let subscription = provider.fetchSubscriptionSummary()
    async let stats = provider.fetchDashboardStats()
    async let trend = provider.fetchUsageTrend(startDate: "2026-09-11", endDate: "2026-09-17", granularity: "day")
    async let models = provider.fetchModelUsage(startDate: "2026-09-11", endDate: "2026-09-17")
    async let realtime = provider.fetchRealtimeMetrics()
    async let health = provider.fetchAccountHealth()

    _ = try await currentUser
    _ = try await subscription
    _ = try await stats
    _ = try await trend
    _ = try await models
    _ = try await realtime
    _ = try await health
}

@Suite(.serialized)
struct CodexProxyRequestBudgetTests {
    @Test func refreshStaysWithinRequestBudget() async throws {
        let counter = StubURLProtocol.reset()
        // Mid-month, so the today and month-to-date windows genuinely differ.
        let provider = CodexProxyDataProvider(
            config: stubbedConfig(),
            session: stubbedSession(),
            now: fixedClock(day: 17)
        )

        try await exerciseFullRefresh(provider)

        #expect(counter.count("/api/user/profile") == 1)
        #expect(counter.count("/api/user/request-usage") == 1)
        #expect(counter.count("/api/user/usage/records/summary") == 2)
        #expect(counter.count("/api/user/usage/insights/overview") == 2)
        #expect(counter.count("/api/user/usage/insights/diagnostics") == 1)
        #expect(counter.total == 7)
    }

    @Test func collapsesSummaryRequestOnFirstOfMonth() async throws {
        let counter = StubURLProtocol.reset()
        // On the 1st both windows start at the same midnight, so the cache
        // collapses them into one request. Six is correct that day, not a bug.
        let provider = CodexProxyDataProvider(
            config: stubbedConfig(),
            session: stubbedSession(),
            now: fixedClock(day: 1)
        )

        try await exerciseFullRefresh(provider)

        #expect(counter.count("/api/user/usage/records/summary") == 1)
        #expect(counter.total == 6)
    }
}

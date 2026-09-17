import Foundation
import Testing
@testable import Sub2APIStatusCore

// Payloads below are captured from a live codex-proxy-rs deployment (adalinkon
// fork, regular-user role) with identifiers and amounts generalised.

private func decode<Value: Decodable & Sendable>(_ json: String, as _: Value.Type) throws -> Value {
    try JSONDecoder.codexProxy.decode(Value.self, from: Data(json.utf8))
}

private func decodeEnvelope<Value: Decodable & Sendable>(_ json: String, as _: Value.Type) throws -> Value {
    try decode(json, as: CodexProxyEnvelope<Value>.self).value()
}

// MARK: - Envelope

@Test func codexProxyEnvelopeAcceptsHTTPStyleSuccessCode() throws {
    // The server mirrors the HTTP status into `code`, so 200 means success.
    let value = try decodeEnvelope(
        #"{"code":200,"message":"OK","data":{"expiresAt":"2026-09-18T00:40:52.501387403+00:00"}}"#,
        as: CodexProxyAuthResponse.self
    )
    #expect(value.expiresAt == "2026-09-18T00:40:52.501387403+00:00")
    #expect(value.role == nil)
}

@Test func codexProxyEnvelopeStillAcceptsZeroSuccessCode() throws {
    let value = try decodeEnvelope(
        #"{"code":0,"message":"OK","data":{"currentConcurrency":1,"currentRpm":2}}"#,
        as: CodexProxyRequestUsage.self
    )
    #expect(value.currentConcurrency == 1)
}

@Test func codexProxyEnvelopeSurfacesApplicationError() throws {
    #expect(throws: CodexProxyError.api(code: 40101, message: "需要登录")) {
        try decodeEnvelope(#"{"code":40101,"message":"需要登录","data":null}"#, as: CodexProxyUserProfile.self)
    }
}

// MARK: - Session cookie

@Test func codexProxySessionCookieIsExtractedFromResponseHeader() throws {
    let url = try #require(URL(string: "https://example.com/api/admin/auth/login"))
    let response = try #require(HTTPURLResponse(
        url: url,
        statusCode: 200,
        httpVersion: "HTTP/1.1",
        headerFields: [
            "Content-Type": "application/json",
            "Set-Cookie": "cpr_admin_session=session_4qctH45-tJqXnz11; Path=/; Secure; HttpOnly; SameSite=Lax",
        ]
    ))

    #expect(CodexProxyClient.sessionCookie(in: response) == "session_4qctH45-tJqXnz11")
}

@Test func codexProxySessionCookieIsAbsentWhenServerSendsNone() throws {
    let url = try #require(URL(string: "https://example.com/api/admin/auth/login"))
    let response = try #require(HTTPURLResponse(
        url: url,
        statusCode: 200,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/json"]
    ))

    #expect(CodexProxyClient.sessionCookie(in: response) == nil)
}

// MARK: - Auth status

@Test func codexProxyAuthStatusDecodesUserPayload() throws {
    let status = try decodeEnvelope(
        #"{"code":200,"message":"OK","data":{"authenticated":true,"user":{"id":"user@example.com","username":"user@example.com","role":"user"}}}"#,
        as: CodexProxyAuthStatusResponse.self
    )
    #expect(status.authenticated)
    #expect(status.user?.role == "user")
}

// MARK: - Error classification

@Test func codexProxyErrorDistinguishesExpiredSessionFromBadCredentials() {
    // 40101 means the session is gone and a silent re-login can recover.
    #expect(CodexProxyError.api(code: 40101, message: "需要登录").isUnauthorized)
    #expect(CodexProxyError.badStatus(401, "Unauthorized").isUnauthorized)

    // 40102 is a rejected password; re-logging in would only repeat the failure.
    #expect(!CodexProxyError.api(code: 40102, message: "用户名或密码错误").isUnauthorized)
}

// MARK: - User profile

@Test func codexProxyUserProfileDecodesQuotaPayload() throws {
    let profile = try decodeEnvelope(
        #"""
        {"code":200,"message":"OK","data":{"id":"user@example.com","username":"user@example.com","role":"user","enabled":true,
        "groups":[{"id":"grp_01","name":"pro","color":"#60A5FA80","enabled":true}],
        "maxConcurrency":0,"requestsPerMinute":0,"keyCount":2,
        "dailyLimitUsd":"300","weeklyLimitUsd":"1000","dailyUsedUsd":"0","weeklyUsedUsd":"167.0104082",
        "dailyRemainingUsd":"300","weeklyRemainingUsd":"832.9895918",
        "dailyResetsAt":"2026-09-17T16:00:00Z","weeklyResetsAt":"2026-09-20T16:00:00Z"}}
        """#,
        as: CodexProxyUserProfile.self
    )

    #expect(profile.role == "user")
    #expect(profile.keyCount == 2)
    #expect(profile.dailyLimit == 300)
    #expect(abs(profile.weeklyUsed - 167.0104082) < 0.000001)
    #expect(abs((profile.weeklyRemaining ?? 0) - 832.9895918) < 0.000001)
    #expect(profile.groups.first?.name == "pro")

    let summary = CodexProxyAdapters.toSubscriptionSummary(profile)
    #expect(summary.subscriptions.count == 1)
    #expect(summary.subscriptions.first?.weeklyLimitUSD == 1000)
    #expect((summary.subscriptions.first?.dailyResetInSeconds ?? 0) > 0)
}

// MARK: - Request usage

@Test func codexProxyRequestUsageDecodesArrayPayload() throws {
    // This endpoint returns one entry per user, not a single object.
    let usage = try decodeEnvelope(
        #"{"code":200,"message":"OK","data":[{"id":"user@example.com","currentConcurrency":3,"currentRpm":7}]}"#,
        as: [CodexProxyRequestUsage].self
    )

    #expect(usage.count == 1)
    #expect(usage.entry(for: "user@example.com").currentConcurrency == 3)
    #expect(usage.entry(for: "someone-else").currentRpm == 7)
    #expect(usage.entry(for: nil).currentConcurrency == 3)
    #expect([CodexProxyRequestUsage]().entry(for: nil) == CodexProxyRequestUsage())
}

// MARK: - Usage summary

@Test func codexProxyUsageSummaryReadsExactNumbersNotDisplayStrings() throws {
    // Top-level fields are display strings ("1.1K", "112.6M"); the exact figures
    // live in logicalRequests and the money in attempts.costs.
    let summary = try decodeEnvelope(
        #"""
        {"code":200,"message":"OK","data":{"totalRequests":"1.1K","inputTokens":"112.6M","outputTokens":"362.8K",
        "cachedTokens":"108.2M","cacheWriteTokens":"0","totalTokens":"112.9M","averageLatencyMs":"13.69 s",
        "logicalRequests":{"requestCount":1142,"successCount":1128,"failureCount":8,"cancelledCount":4,
        "incompleteCount":2,"callerErrorCount":0,"inputTokens":112585994,"outputTokens":362788,
        "cachedTokens":108216064,"cacheWriteTokens":0,"reasoningTokens":116996,"totalTokens":112948782},
        "attempts":{"attemptCount":1135,"successCount":1128,"failureCount":1,"cancelledCount":4,"incompleteCount":2,
        "rateLimitedCount":0,"authFailureCount":0,"provider5xxCount":1,
        "costCoverage":{"known":1123,"partial":0,"unknown":5,"notBillable":0},
        "costs":[{"currency":"USD","estimatedAmount":"167.0104082"}]}}}
        """#,
        as: CodexProxyUsageSummary.self
    )

    #expect(summary.requests == 1142)
    #expect(summary.failedRequests == 8)
    #expect(summary.inputTokens == 112_585_994)
    #expect(summary.outputTokens == 362_788)
    #expect(summary.cachedTokens == 108_216_064)
    #expect(summary.reasoningTokens == 116_996)
    #expect(summary.totalTokens == 112_948_782)
    #expect(abs(summary.cost - 167.0104082) < 0.000001)
}

// MARK: - Insights overview

// Shared with CodexProxyRequestBudgetTests.
let overviewJSON = #"""
{"code":200,"message":"OK","data":{"granularity":"1h",
"health":{"totalRequests":10,"successRequests":9,"failedRequests":1,"cancelledRequests":0,
"incompleteRequests":0,"callerErrorRequests":0,"successRate":0.9,"completionRate":0.9,
"requestChangeRate":null,"successRateChange":null,
"points":[{"bucket":"2026-09-17T00:00:00Z","label":"09-17 08:00","totalRequests":4,"successRequests":4,
"failedRequests":0,"cancelledRequests":0,"incompleteRequests":0,"callerErrorRequests":0,"errorRate":0.0},
{"bucket":"2026-09-17T01:00:00Z","label":"09-17 09:00","totalRequests":6,"successRequests":5,
"failedRequests":1,"cancelledRequests":0,"incompleteRequests":0,"callerErrorRequests":0,"errorRate":0.166}]},
"performance":{"latencyP50Ms":1200.5,"latencyP95Ms":4000,"latencyP99Ms":null,"firstTokenP50Ms":300,
"firstTokenP95Ms":null,"firstTokenP99Ms":null,"points":[]},
"cost":{"estimatedCost":"29.06","standardCost":"177.1","noCacheCost":"177.1","cacheSavings":"148.05",
"tierPremium":"0","costPerRequest":"2.9","costPerSuccessfulRequest":"3.2","tokensPerRequest":15.0,
"cachedTokenRate":0.53,"cacheHitRequestRate":0.5,"inputTokens":100,"outputTokens":50,"cachedTokens":80,
"totalTokens":150,
"points":[{"bucket":"2026-09-17T00:00:00Z","label":"09-17 08:00","inputTokens":40,"outputTokens":20,
"cachedTokens":30,"totalTokens":60,"estimatedCost":"10.5","standardCost":"40.0","cacheSavings":"29.5"},
{"bucket":"2026-09-17T01:00:00Z","label":"09-17 09:00","inputTokens":60,"outputTokens":30,
"cachedTokens":50,"totalTokens":90,"estimatedCost":"18.56","standardCost":"137.1","cacheSavings":"118.54"}]},
"attempts":{"attemptCount":10,"successCount":9,"failureCount":1,"cancelledCount":0,"incompleteCount":0,
"rateLimitedCount":0,"authFailureCount":0,"provider5xxCount":0,
"costCoverage":{"known":10,"partial":0,"unknown":0,"notBillable":0},
"costs":[{"currency":"USD","estimatedAmount":"29.06"}]},
"providers":[{"provider":"openai","requestCount":10,"attemptCount":10,"failureCount":1,"totalTokens":150}]}}
"""#

@Test func codexProxyOverviewMergesHealthAndCostPointsIntoTrend() throws {
    // There is no single `trend` array: request counts come from health.points and
    // token/cost figures from cost.points, joined on `bucket`.
    let overview = try decodeEnvelope(overviewJSON, as: CodexProxyUsageOverview.self)
    #expect(overview.granularity == "1h")

    let trend = CodexProxyAdapters.toTrendDataPoints(overview)
    #expect(trend.count == 2)
    #expect(trend[0].date == "2026-09-17T00:00:00Z")
    #expect(trend[0].requests == 4)
    #expect(trend[0].inputTokens == 40)
    #expect(trend[0].outputTokens == 20)
    #expect(trend[0].cacheReadTokens == 30)
    #expect(trend[0].totalTokens == 60)
    #expect(abs(trend[0].cost - 10.5) < 0.000001)
    #expect(trend[1].requests == 6)
    #expect(trend[1].totalTokens == 90)
    #expect(abs(trend[1].cost - 18.56) < 0.000001)

    #expect(abs(overview.averageLatencyMs - 1200.5) < 0.000001)
    #expect(abs(overview.successRate - 0.9) < 0.000001)
    #expect(abs(overview.errorRate - 0.1) < 0.000001)
}

@Test func codexProxyOverviewReportsZeroErrorRateWhenIdle() throws {
    // An idle window returns successRate 0, which must not read as 100% failures.
    let idle = try decodeEnvelope(
        #"""
        {"code":200,"message":"OK","data":{"granularity":"1h",
        "health":{"totalRequests":0,"successRequests":0,"failedRequests":0,"successRate":0.0,"points":[]},
        "performance":{"latencyP50Ms":null},"cost":{"points":[]}}}
        """#,
        as: CodexProxyUsageOverview.self
    )

    #expect(idle.errorRate == 0)
    #expect(idle.averageLatencyMs == 0)
    #expect(idle.trendPoints.isEmpty)
}

// MARK: - Diagnostics

@Test func codexProxyDiagnosticsMapsToModelUsage() throws {
    let diagnostics = try decodeEnvelope(
        #"""
        {"code":200,"message":"OK","data":{"dimension":"model","items":[
        {"key":"gpt-5.6-luna","name":"gpt-5.6-luna","requestCount":29,"successCount":27,"errorCount":2,
        "errorRate":0.0689,"requestShare":0.025,"averageLatencyMs":3269,"latencyP95Ms":5045,
        "firstTokenP95Ms":2801,"nonCompletionCount":0,"nonCompletionRate":0.0,"retryCount":0,"retryRate":0.0,
        "impactScore":0.036,"estimatedCost":"0.0509742","attemptCount":27,"totalTokens":300233},
        {"key":"gpt-6-astra","name":"gpt-6-astra","requestCount":1113,"successCount":1101,"errorCount":6,
        "errorRate":0.0053,"requestShare":0.974,"averageLatencyMs":13946,"latencyP95Ms":40557,
        "firstTokenP95Ms":7504,"nonCompletionCount":6,"nonCompletionRate":0.0053,"retryCount":0,"retryRate":0.0,
        "impactScore":0.125,"estimatedCost":"166.959434","attemptCount":1108,"totalTokens":112648549}]}}
        """#,
        as: CodexProxyDiagnosticsResponse.self
    )

    #expect(diagnostics.dimension == "model")

    let models = CodexProxyAdapters.toModelUsageSummaries(diagnostics.items)
    #expect(models.count == 2)
    // Sorted by token usage, so the heavier model leads.
    #expect(models[0].model == "gpt-6-astra")
    #expect(models[0].requests == 1113)
    #expect(models[0].totalTokens == 112_648_549)
    #expect(abs(models[0].actualCost - 166.959434) < 0.000001)
    #expect(models[1].model == "gpt-5.6-luna")
    #expect(abs(models[1].actualCost - 0.0509742) < 0.000001)
}

@Test func modelUsageDisplayOmitsTokenMixWhenProviderReportsNoSplit() {
    // codex-proxy-rs has no per-model input/output breakdown; rendering zeros
    // would be misleading, so the mix line is left empty.
    let withoutSplit = ModelUsageDisplay.make([
        ModelUsageSummary(
            model: "gpt-6-astra", requests: 1113, totalTokens: 100, inputTokens: 0, outputTokens: 0,
            cacheCreationTokens: 0, cacheReadTokens: 0, cost: 10, actualCost: 10, accountCost: 10, standardCost: 10
        ),
    ])
    #expect(withoutSplit.first?.tokenMixText == "")
    #expect(withoutSplit.first?.tokensText.isEmpty == false)

    let withSplit = ModelUsageDisplay.make([
        ModelUsageSummary(
            model: "gpt-6-astra", requests: 10, totalTokens: 100, inputTokens: 60, outputTokens: 40,
            cacheCreationTokens: 0, cacheReadTokens: 0, cost: 10, actualCost: 10, accountCost: 10, standardCost: 10
        ),
    ])
    #expect(withSplit.first?.tokenMixText.contains("In") == true)
    #expect(withSplit.first?.tokenMixText.contains("Out") == true)
}

// MARK: - Usage records

@Test func codexProxyRecordBillingParsesDisplayAmounts() throws {
    // Record-level billing is rendered for the web UI, so amounts arrive as
    // display strings like "$0.0726".
    let page = try decodeEnvelope(
        #"""
        {"code":200,"message":"OK","data":{"items":[
        {"id":"req_01","provider":"openai","route":"/v1/responses","model":"gpt-6-astra",
        "requestedModel":"gpt-6-astra","upstreamModel":"gpt-6-astra","serviceTier":null,
        "clientTransport":"http_sse","upstreamTransport":"websocket","reasoningEffort":"low","compact":false,
        "tokenDetails":{"inputTokens":67919,"outputTokens":56,"cachedTokens":67712,"cacheWriteTokens":0,
        "reasoningTokens":0,"imageInputTokens":0,"imageOutputTokens":0,"totalTokens":67975,
        "inputTokensDisplay":"67,919","totalTokensDisplay":"67,975"},
        "billing":{"inputAmountDisplay":"$0.0021","outputAmountDisplay":"$0.0028",
        "cacheReadAmountDisplay":"$0.0677","cacheWriteAmountDisplay":"$0.00",
        "standardAmountDisplay":"$0.5000","totalAmountDisplay":"$0.0726",
        "serviceTierDisplay":"Standard","multiplierDisplay":"1.00x"},
        "latencyDetails":{"admissionDecisionMs":4,"firstTokenMs":5741},
        "firstTokenLatencyMs":5741,"latencyMs":7473,
        "createdAt":"2026-09-16T14:03:51.305858Z","createdAtDisplay":"2026-09-16 22:03:51",
        "clientIp":"127.0.0.1","userAgent":"pi (darwin 25.6.0; arm64)"}],
        "currentPage":1,"pageSize":100,"total":1128}}
        """#,
        as: CodexProxyUsageRecordsResponse.self
    )

    #expect(page.total == 1128)
    #expect(page.currentPage == 1)
    let record = try #require(page.items.first)
    #expect(record.model == "gpt-6-astra")
    #expect(record.tokenDetails?.totalTokens == 67_975)
    #expect(record.tokenDetails?.cachedTokens == 67_712)
    #expect(abs((record.billing?.cost ?? 0) - 0.0726) < 0.000001)
    #expect(abs((record.billing?.standardCost ?? 0) - 0.5) < 0.000001)
    #expect(record.latencyMs == 7473)
    #expect(record.status == "success")
}

// MARK: - Client keys

@Test func codexProxyClientKeysDecodeWithCursorEnvelope() throws {
    let page = try decodeEnvelope(
        #"""
        {"code":200,"message":"OK","data":{"items":[
        {"id":"key_01","userId":"user@example.com","name":"import-002","label":null,"routingScope":"inherit",
        "groups":[],"providerKinds":["openai"],"prefix":"sk-9baa0a0","enabled":true,"maxConcurrency":0,
        "requestsPerMinute":0,"dailyLimitUsd":"0","weeklyLimitUsd":"0","dailyUsedUsd":"0",
        "weeklyUsedUsd":"167.0104082","dailyResetsAt":"2026-09-17T16:00:00Z","weeklyResetsAt":"2026-09-20T16:00:00Z",
        "createdAt":"2026-09-13T23:16:10.870531Z","updatedAt":"2026-09-13T23:16:10.870531Z",
        "lastUsedAt":"2026-09-16T14:03:51.305857Z"}],"total":1,"nextCursor":null}}
        """#,
        as: CodexProxyClientKeysResponse.self
    )

    #expect(page.total == 1)
    #expect(page.nextCursor == nil)
    let key = try #require(page.items.first)
    #expect(key.name == "import-002")
    #expect(key.label == nil)
    #expect(abs(key.weeklyUsed - 167.0104082) < 0.000001)
    #expect(key.lastUsedAt != nil)

    let accounts = CodexProxyAdapters.toAccountSummaries([key])
    #expect(accounts.first?.quotaWeeklyUsed == key.weeklyUsed)
}

// MARK: - Adapters

@Test func codexProxyStableIDIsDeterministic() {
    // Swift's hashValue is seeded per process, so IDs built from it changed on
    // every launch and broke identity across restarts.
    #expect(CodexProxyAdapters.stableID("user@example.com") == CodexProxyAdapters.stableID("user@example.com"))
    #expect(CodexProxyAdapters.stableID("a") != CodexProxyAdapters.stableID("b"))

    let first = CodexProxyAdapters.toCurrentUser(
        try! decodeEnvelope(
            #"{"code":200,"message":"OK","data":{"id":"user@example.com","username":"user@example.com","role":"user","enabled":true}}"#,
            as: CodexProxyUserProfile.self
        )
    )
    #expect(first.id == CodexProxyAdapters.stableID("user@example.com"))
    #expect(first.role == "user")
    #expect(first.balance == nil)
}

@Test func codexProxyRealtimeMetricsUseLatencyAndErrorRate() throws {
    let overview = try decodeEnvelope(overviewJSON, as: CodexProxyUsageOverview.self)
    let metrics = CodexProxyAdapters.toRealtimeMetrics(
        requestUsage: CodexProxyRequestUsage(id: "user@example.com", currentConcurrency: 3, currentRpm: 7),
        overview: overview
    )

    #expect(metrics.activeRequests == 3)
    #expect(metrics.requestsPerMinute == 7)
    #expect(abs(metrics.averageResponseTime - 1200.5) < 0.000001)
    #expect(abs(metrics.errorRate - 0.1) < 0.000001)

    // Without an overview the metrics degrade to zeros rather than failing.
    let bare = CodexProxyAdapters.toRealtimeMetrics(requestUsage: CodexProxyRequestUsage(), overview: nil)
    #expect(bare.errorRate == 0)
    #expect(bare.averageResponseTime == 0)
}

// MARK: - Date handling

@Test func codexProxyDateParsesEveryFormatTheServerUses() throws {
    #expect(CodexProxyDate.parse("2026-09-17T16:00:00Z") != nil)
    #expect(CodexProxyDate.parse("2026-09-13T23:16:10.870531Z") != nil)
    #expect(CodexProxyDate.parse("2026-09-18T00:40:52.501387403+00:00") != nil)
    #expect(CodexProxyDate.parse("2026-09-17") != nil)
    #expect(CodexProxyDate.parse("") == nil)
    #expect(CodexProxyDate.parse("not-a-date") == nil)
}

@Test func codexProxyDateExpandsDayBoundariesIntoAnInclusiveRange() throws {
    // ISO8601DateFormatter cannot parse "2026-09-17" at all, which silently made
    // every trend request fail.
    let range = try #require(CodexProxyDate.rangeBoundaries(start: "2026-09-11", end: "2026-09-17"))
    #expect(range.start < range.end)

    let calendar = Calendar(identifier: .gregorian)
    let days = calendar.dateComponents([.day], from: range.start, to: range.end).day
    // Seven inclusive days minus one second.
    #expect(days == 6)
    #expect(CodexProxyDate.rangeBoundaries(start: "bogus", end: "2026-09-17") == nil)
}

// MARK: - Credential persistence

private func temporaryConfigURL() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "Sub2APIStatusBarTests-\(UUID().uuidString).json")
}

@Test func configStorePersistsCodexProxySessionCookieAndPassword() throws {
    let url = temporaryConfigURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let store = ConfigStore(configURL: url, environment: [:])

    var config = AppConfig(provider: .codexProxy, baseURL: "https://example.com")
    config.upsertAccount(
        name: "user@example.com",
        email: "user@example.com",
        baseURL: "https://example.com",
        tokens: StoredAuthTokens(authToken: "session_abc123", password: "secret")
    )
    #expect(config.hasUsableCredentials)
    try store.save(config)

    let loaded = store.load()
    #expect(loaded.provider == .codexProxy)
    #expect(loaded.authToken == "session_abc123")
    #expect(loaded.password == "secret")
    #expect(loaded.selectedAccount?.password == "secret")
    #expect(loaded.hasUsableCredentials)
}

@Test func configStoreLoadsAccountWrittenBeforePasswordExisted() throws {
    let url = temporaryConfigURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let legacy = #"""
    {"provider":"codexProxy","baseURL":"https://example.com","authToken":"","refreshToken":"",
    "refreshIntervalSeconds":15,"accounts":[{"id":"a1","name":"user@example.com","email":"user@example.com",
    "baseURL":"https://example.com","authToken":"session_legacy","refreshToken":""}],"selectedAccountID":"a1"}
    """#
    try Data(legacy.utf8).write(to: url)

    let loaded = ConfigStore(configURL: url, environment: [:]).load()
    #expect(loaded.authToken == "session_legacy")
    #expect(loaded.password == "")
    #expect(loaded.accounts.count == 1)
    #expect(loaded.hasUsableCredentials)
}

@Test func codexProxyCredentialsSurviveDisconnect() throws {
    let url = temporaryConfigURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let store = ConfigStore(configURL: url, environment: [:])

    var config = AppConfig(provider: .codexProxy, baseURL: "https://example.com")
    config.upsertAccount(
        name: "user@example.com",
        email: "user@example.com",
        baseURL: "https://example.com",
        tokens: StoredAuthTokens(authToken: "session_abc123", password: "secret")
    )
    try store.save(config)

    // Removing the only account must drop the password too, not leave it behind.
    var disconnected = store.load()
    disconnected.accounts.removeAll()
    disconnected.selectedAccountID = nil
    disconnected.clearAuthTokens()
    try store.save(disconnected)

    let reloaded = store.load()
    #expect(reloaded.password == "")
    #expect(reloaded.authToken == "")
    #expect(!reloaded.hasUsableCredentials)
}

@Test func codexProxyNeedsACookieOrPasswordToBeUsable() {
    // Merely having a selected account is not enough: the account has to carry a
    // session cookie or a password it can re-authenticate with.
    var empty = AppConfig(provider: .codexProxy, baseURL: "https://example.com")
    empty.upsertAccount(name: "user@example.com", baseURL: "https://example.com", tokens: StoredAuthTokens())
    #expect(!empty.hasUsableCredentials)

    var cookieOnly = AppConfig(provider: .codexProxy, baseURL: "https://example.com")
    cookieOnly.upsertAccount(
        name: "user@example.com",
        baseURL: "https://example.com",
        tokens: StoredAuthTokens(authToken: "session_abc")
    )
    #expect(cookieOnly.hasUsableCredentials)

    var passwordOnly = AppConfig(provider: .codexProxy, baseURL: "https://example.com")
    passwordOnly.upsertAccount(
        name: "user@example.com",
        baseURL: "https://example.com",
        tokens: StoredAuthTokens(password: "secret")
    )
    #expect(passwordOnly.hasUsableCredentials)
}

@Test func codexProxyBaseURLSkipsTheSub2APIVersionPrefix() {
    var config = AppConfig(provider: .codexProxy, baseURL: "https://example.com/")
    config.normalize()
    #expect(config.apiBaseURL?.absoluteString == "https://example.com")

    var sub2api = AppConfig(provider: .sub2api, baseURL: "https://example.com")
    sub2api.normalize()
    #expect(sub2api.apiBaseURL?.absoluteString == "https://example.com/api/v1/")
}

// MARK: - Reporting windows

private func beijingCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    return calendar
}

@Test func codexProxyReportingWindowsAnchorToLocalDayAndMonth() throws {
    let calendar = beijingCalendar()
    // 2026-09-17 15:30 Beijing time.
    let now = try #require(calendar.date(from: DateComponents(
        year: 2026, month: 9, day: 17, hour: 15, minute: 30
    )))

    let today = CodexProxyDate.todayWindow(now: now, calendar: calendar)
    #expect(today.start == calendar.startOfDay(for: now))
    #expect(today.end == now)

    let month = CodexProxyDate.monthToDateWindow(now: now, calendar: calendar)
    let expectedMonthStart = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 1)))
    #expect(month.start == expectedMonthStart)
    #expect(month.end == now)
    #expect(month.start < today.start)
}

@Test func codexProxyReportingWindowsCoincideOnFirstOfMonth() throws {
    let calendar = beijingCalendar()
    // On the 1st, month-to-date and today share the same start, so only one
    // summary request is issued and the two rows read identically.
    let now = try #require(calendar.date(from: DateComponents(
        year: 2026, month: 9, day: 1, hour: 9, minute: 0
    )))

    let today = CodexProxyDate.todayWindow(now: now, calendar: calendar)
    let month = CodexProxyDate.monthToDateWindow(now: now, calendar: calendar)
    #expect(today.start == month.start)
}

// MARK: - Dashboard stats separation

private func makeSummary(requests: Int, totalTokens: Int, cost: String) throws -> CodexProxyUsageSummary {
    let json = """
    {"code":200,"message":"OK","data":{"logicalRequests":{"requestCount":\(requests),"successCount":\(requests),"failureCount":0,"inputTokens":\(totalTokens),"outputTokens":0,"cachedTokens":0,"cacheWriteTokens":0,"reasoningTokens":0,"totalTokens":\(totalTokens)},"attempts":{"attemptCount":\(requests),"successCount":\(requests),"failureCount":0,"costs":[{"currency":"USD","estimatedAmount":"\(cost)"}]}}}
    """
    return try decodeEnvelope(json, as: CodexProxyUsageSummary.self)
}

@Test func codexProxyDashboardStatsSeparatesTodayFromMonth() throws {
    let today = try makeSummary(requests: 12, totalTokens: 3_400, cost: "5.5")
    let month = try makeSummary(requests: 480, totalTokens: 990_000, cost: "210.25")
    let profile = try decodeEnvelope(
        #"{"code":200,"message":"OK","data":{"id":"user@example.com","username":"user@example.com","role":"user","enabled":true,"keyCount":2}}"#,
        as: CodexProxyUserProfile.self
    )

    let stats = CodexProxyAdapters.toDashboardStats(
        todaySummary: today,
        monthSummary: month,
        profile: profile,
        realtimeUsage: CodexProxyRequestUsage(id: "user@example.com", currentConcurrency: 1, currentRpm: 7),
        realtimeOverview: nil
    )

    #expect(stats.todayRequests == 12)
    #expect(stats.totalRequests == 480)
    #expect(stats.todayRequests != stats.totalRequests)
    #expect(stats.todayTokens == 3_400)
    #expect(stats.totalTokens == 990_000)
    #expect(abs(stats.todayActualCost - 5.5) < 0.000001)
    #expect(abs(stats.totalActualCost - 210.25) < 0.000001)
    // Without an overview, latency and TPM degrade to zero rather than lying.
    #expect(stats.averageDurationMs == 0)
    #expect(stats.tpm == 0)
}

@Test func codexProxyDashboardStatsDerivesLatencyAndTpmFromOverview() throws {
    let overview = try decodeEnvelope(overviewJSON, as: CodexProxyUsageOverview.self)
    // The fixture publishes tokensPerRequest: 15.0.
    #expect(abs(overview.tokensPerRequest - 15.0) < 0.000001)

    let summary = try makeSummary(requests: 10, totalTokens: 150, cost: "1.0")
    let profile = try decodeEnvelope(
        #"{"code":200,"message":"OK","data":{"id":"user@example.com","username":"user@example.com","role":"user","enabled":true}}"#,
        as: CodexProxyUserProfile.self
    )

    let stats = CodexProxyAdapters.toDashboardStats(
        todaySummary: summary,
        monthSummary: summary,
        profile: profile,
        realtimeUsage: CodexProxyRequestUsage(id: "user@example.com", currentConcurrency: 1, currentRpm: 7),
        realtimeOverview: overview
    )

    #expect(abs(stats.averageDurationMs - 1200.5) < 0.000001)
    // tpm = tokensPerRequest (15.0) * currentRpm (7) = 105.
    #expect(abs(stats.tpm - 105.0) < 0.000001)
}

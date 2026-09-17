import Foundation

// MARK: - CodexProxy Error

public enum CodexProxyError: Error, LocalizedError, Equatable, Sendable {
    case api(code: Int, message: String)
    case missingData
    case missingSessionCookie
    case invalidBaseURL
    case invalidDateRange(String, String)
    case badStatus(Int, String)

    public var errorDescription: String? {
        switch self {
        case let .api(code, message):
            "API \(code): \(message)"
        case .missingData:
            "Response did not include data."
        case .missingSessionCookie:
            "The server accepted the login but did not return a session cookie."
        case .invalidBaseURL:
            "Base URL is invalid."
        case let .invalidDateRange(start, end):
            "Date range \(start) to \(end) is invalid."
        case let .badStatus(status, message):
            "HTTP \(status): \(message)"
        }
    }

    public var isUnauthorized: Bool {
        switch self {
        case let .badStatus(status, _):
            status == 401
        case let .api(code, _):
            // 40101 "需要登录" means the session is missing or expired. 40102 is a
            // credential rejection, which re-logging in would only repeat.
            code == 401 || code == Self.sessionExpiredCode
        default:
            false
        }
    }

    static let sessionExpiredCode = 40101
}

// MARK: - CodexProxy Envelope

public struct CodexProxyEnvelope<Value: Decodable & Sendable>: Decodable, Sendable {
    public let code: Int
    public let message: String
    public let data: Value?

    /// codex-proxy-rs mirrors the HTTP status into `code` (200 on success); some
    /// builds use 0 instead.
    public var isSuccess: Bool {
        code == 0 || (200..<300).contains(code)
    }

    public func value() throws -> Value {
        guard isSuccess else {
            throw CodexProxyError.api(code: code, message: message)
        }
        guard let data else {
            throw CodexProxyError.missingData
        }
        return data
    }

    private enum CodingKeys: String, CodingKey {
        case code
        case message
        case data
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decodeIfPresent(Int.self, forKey: .code) ?? 200
        message = try container.decodeIfPresent(String.self, forKey: .message) ?? ""
        data = try container.decodeIfPresent(Value.self, forKey: .data)
    }
}

// MARK: - Number Parsing

enum CodexProxyNumber {
    /// Parses decimal strings returned by codex-proxy-rs. Handles plain decimals
    /// (`"167.0104082"`) and money display strings (`"$0.0726"`).
    static func decimal(from value: String?) -> Double {
        guard let value else { return 0 }
        let cleaned = value.filter { character in
            character.isNumber || character == "." || character == "-"
        }
        guard let firstSeparator = cleaned.firstIndex(of: ".") else {
            return Double(cleaned) ?? 0
        }
        // Keep only the first decimal separator; display strings never nest them.
        let next = cleaned.index(after: firstSeparator)
        return Double(cleaned[..<next] + cleaned[next...].replacingOccurrences(of: ".", with: "")) ?? 0
    }
}

// MARK: - Authentication

public struct CodexProxyLoginRequest: Encodable, Sendable {
    public let username: String
    public let password: String

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }
}

/// Body of a successful login: `{"expiresAt": "2026-09-18T00:40:52.501+00:00"}`.
public struct CodexProxyAuthResponse: Decodable, Sendable {
    public let role: String?
    public let expiresAt: String?
}

public struct CodexProxyAuthStatusUser: Decodable, Equatable, Sendable {
    public let id: String
    public let username: String
    public let role: String
}

/// Body of `/api/admin/auth/status`: `{"authenticated": true, "user": {...}}`.
public struct CodexProxyAuthStatusResponse: Decodable, Sendable {
    public let authenticated: Bool
    public let user: CodexProxyAuthStatusUser?

    private enum CodingKeys: String, CodingKey {
        case authenticated
        case user
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        authenticated = try container.decodeIfPresent(Bool.self, forKey: .authenticated) ?? false
        user = try container.decodeIfPresent(CodexProxyAuthStatusUser.self, forKey: .user)
    }
}

/// The credential returned by login. codex-proxy-rs has no token in the body; the
/// session lives in the `cpr_admin_session` cookie.
public struct CodexProxySession: Equatable, Sendable {
    public var cookie: String
    public var expiresAt: String?

    public init(cookie: String, expiresAt: String? = nil) {
        self.cookie = cookie
        self.expiresAt = expiresAt
    }
}

// MARK: - User Profile

public struct CodexProxyUserProfile: Decodable, Equatable, Sendable {
    public let id: String
    public let username: String
    public let role: String
    public let enabled: Bool
    public let groups: [CodexProxyGroup]
    public let keyCount: Int

    // Quota limits
    public let maxConcurrency: Int
    public let requestsPerMinute: Int
    public let dailyLimitUsd: String
    public let weeklyLimitUsd: String

    // Usage
    public let dailyUsedUsd: String
    public let weeklyUsedUsd: String
    public let dailyRemainingUsd: String?
    public let weeklyRemainingUsd: String?

    // Reset times
    public let dailyResetsAt: String
    public let weeklyResetsAt: String

    private enum CodingKeys: String, CodingKey {
        case id
        case username
        case role
        case enabled
        case groups
        case keyCount
        case maxConcurrency
        case requestsPerMinute
        case dailyLimitUsd
        case weeklyLimitUsd
        case dailyUsedUsd
        case weeklyUsedUsd
        case dailyRemainingUsd
        case weeklyRemainingUsd
        case dailyResetsAt
        case weeklyResetsAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        username = try container.decodeIfPresent(String.self, forKey: .username) ?? (try container.decode(String.self, forKey: .id))
        role = try container.decodeIfPresent(String.self, forKey: .role) ?? "user"
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        groups = try container.decodeIfPresent([CodexProxyGroup].self, forKey: .groups) ?? []
        keyCount = try container.decodeIfPresent(Int.self, forKey: .keyCount) ?? 0
        maxConcurrency = try container.decodeIfPresent(Int.self, forKey: .maxConcurrency) ?? 0
        requestsPerMinute = try container.decodeIfPresent(Int.self, forKey: .requestsPerMinute) ?? 0
        dailyLimitUsd = try container.decodeIfPresent(String.self, forKey: .dailyLimitUsd) ?? "0"
        weeklyLimitUsd = try container.decodeIfPresent(String.self, forKey: .weeklyLimitUsd) ?? "0"
        dailyUsedUsd = try container.decodeIfPresent(String.self, forKey: .dailyUsedUsd) ?? "0"
        weeklyUsedUsd = try container.decodeIfPresent(String.self, forKey: .weeklyUsedUsd) ?? "0"
        dailyRemainingUsd = try container.decodeIfPresent(String.self, forKey: .dailyRemainingUsd)
        weeklyRemainingUsd = try container.decodeIfPresent(String.self, forKey: .weeklyRemainingUsd)
        dailyResetsAt = try container.decodeIfPresent(String.self, forKey: .dailyResetsAt) ?? ""
        weeklyResetsAt = try container.decodeIfPresent(String.self, forKey: .weeklyResetsAt) ?? ""
    }

    // Computed properties for easier access
    public var dailyLimit: Double {
        CodexProxyNumber.decimal(from: dailyLimitUsd)
    }

    public var weeklyLimit: Double {
        CodexProxyNumber.decimal(from: weeklyLimitUsd)
    }

    public var dailyUsed: Double {
        CodexProxyNumber.decimal(from: dailyUsedUsd)
    }

    public var weeklyUsed: Double {
        CodexProxyNumber.decimal(from: weeklyUsedUsd)
    }

    public var dailyRemaining: Double? {
        guard let dailyRemainingUsd else { return nil }
        return CodexProxyNumber.decimal(from: dailyRemainingUsd)
    }

    public var weeklyRemaining: Double? {
        guard let weeklyRemainingUsd else { return nil }
        return CodexProxyNumber.decimal(from: weeklyRemainingUsd)
    }

    public var dailyProgress: Double? {
        guard dailyLimit > 0 else { return nil }
        return dailyUsed / dailyLimit
    }

    public var weeklyProgress: Double? {
        guard weeklyLimit > 0 else { return nil }
        return weeklyUsed / weeklyLimit
    }
}

public struct CodexProxyGroup: Decodable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let color: String

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case color
    }

    public init(id: String, name: String, color: String) {
        self.id = id
        self.name = name
        self.color = color
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        color = try container.decodeIfPresent(String.self, forKey: .color) ?? ""
    }
}

// MARK: - Client Keys

public struct CodexProxyClientKey: Decodable, Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let label: String?
    public let prefix: String
    public let enabled: Bool
    public let createdAt: String
    public let lastUsedAt: String?

    // Key-specific limits (additional to user limits)
    public let dailyLimitUsd: String
    public let weeklyLimitUsd: String
    public let dailyUsedUsd: String
    public let weeklyUsedUsd: String
    public let maxConcurrency: Int
    public let requestsPerMinute: Int

    // Routing
    public let routingScope: String  // "all" or "inherit"
    public let groups: [CodexProxyGroup]

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case label
        case prefix
        case enabled
        case createdAt
        case lastUsedAt
        case dailyLimitUsd
        case weeklyLimitUsd
        case dailyUsedUsd
        case weeklyUsedUsd
        case maxConcurrency
        case requestsPerMinute
        case routingScope
        case groups
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        label = try container.decodeIfPresent(String.self, forKey: .label)
        prefix = try container.decodeIfPresent(String.self, forKey: .prefix) ?? ""
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        lastUsedAt = try container.decodeIfPresent(String.self, forKey: .lastUsedAt)
        dailyLimitUsd = try container.decodeIfPresent(String.self, forKey: .dailyLimitUsd) ?? "0"
        weeklyLimitUsd = try container.decodeIfPresent(String.self, forKey: .weeklyLimitUsd) ?? "0"
        dailyUsedUsd = try container.decodeIfPresent(String.self, forKey: .dailyUsedUsd) ?? "0"
        weeklyUsedUsd = try container.decodeIfPresent(String.self, forKey: .weeklyUsedUsd) ?? "0"
        maxConcurrency = try container.decodeIfPresent(Int.self, forKey: .maxConcurrency) ?? 0
        requestsPerMinute = try container.decodeIfPresent(Int.self, forKey: .requestsPerMinute) ?? 0
        routingScope = try container.decodeIfPresent(String.self, forKey: .routingScope) ?? "inherit"
        groups = try container.decodeIfPresent([CodexProxyGroup].self, forKey: .groups) ?? []
    }

    public var dailyLimit: Double { CodexProxyNumber.decimal(from: dailyLimitUsd) }
    public var weeklyLimit: Double { CodexProxyNumber.decimal(from: weeklyLimitUsd) }
    public var dailyUsed: Double { CodexProxyNumber.decimal(from: dailyUsedUsd) }
    public var weeklyUsed: Double { CodexProxyNumber.decimal(from: weeklyUsedUsd) }
}

/// `/api/user/client-keys` returns `{"items": [...], "total": n, "nextCursor": null}`.
public struct CodexProxyClientKeysResponse: Decodable, Sendable {
    public let items: [CodexProxyClientKey]
    public let total: Int
    public let nextCursor: String?

    private enum CodingKeys: String, CodingKey {
        case items
        case total
        case nextCursor
    }

    public init(items: [CodexProxyClientKey], total: Int = 0, nextCursor: String? = nil) {
        self.items = items
        self.total = total
        self.nextCursor = nextCursor
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decodeIfPresent([CodexProxyClientKey].self, forKey: .items) ?? []
        total = try container.decodeIfPresent(Int.self, forKey: .total) ?? items.count
        nextCursor = try container.decodeIfPresent(String.self, forKey: .nextCursor)
    }
}

// MARK: - Usage Records

public struct CodexProxyUsageRecord: Decodable, Identifiable, Equatable, Sendable {
    public let id: String
    public let createdAt: String
    public let model: String?
    public let route: String?
    public let reasoningEffort: String?
    public let clientTransport: String?
    public let upstreamTransport: String?

    // Token details
    public let tokenDetails: CodexProxyTokenDetails?

    // Billing
    public let billing: CodexProxyBilling?

    // Latency
    public let latencyMs: Int?
    public let firstTokenLatencyMs: Int?

    // Client info
    public let clientIp: String?
    public let userAgent: String?

    // Status
    public let status: String  // "success" or "error"
    public let statusCode: Int?

    private enum CodingKeys: String, CodingKey {
        case id
        case createdAt
        case model
        case route
        case reasoningEffort
        case clientTransport
        case upstreamTransport
        case tokenDetails
        case billing
        case latencyMs
        case firstTokenLatencyMs
        case clientIp
        case userAgent
        case status
        case statusCode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        model = try container.decodeIfPresent(String.self, forKey: .model)
        route = try container.decodeIfPresent(String.self, forKey: .route)
        reasoningEffort = try container.decodeIfPresent(String.self, forKey: .reasoningEffort)
        clientTransport = try container.decodeIfPresent(String.self, forKey: .clientTransport)
        upstreamTransport = try container.decodeIfPresent(String.self, forKey: .upstreamTransport)
        tokenDetails = try container.decodeIfPresent(CodexProxyTokenDetails.self, forKey: .tokenDetails)
        billing = try container.decodeIfPresent(CodexProxyBilling.self, forKey: .billing)
        latencyMs = try container.decodeIfPresent(Int.self, forKey: .latencyMs)
        firstTokenLatencyMs = try container.decodeIfPresent(Int.self, forKey: .firstTokenLatencyMs)
        clientIp = try container.decodeIfPresent(String.self, forKey: .clientIp)
        userAgent = try container.decodeIfPresent(String.self, forKey: .userAgent)
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? "success"
        statusCode = try container.decodeIfPresent(Int.self, forKey: .statusCode)
    }
}

public struct CodexProxyTokenDetails: Decodable, Equatable, Sendable {
    public let inputTokens: Int
    public let outputTokens: Int
    public let cachedTokens: Int
    public let cacheWriteTokens: Int
    public let reasoningTokens: Int
    public let totalTokens: Int

    private enum CodingKeys: String, CodingKey {
        case inputTokens
        case outputTokens
        case cachedTokens
        case cacheWriteTokens
        case reasoningTokens
        case totalTokens
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        inputTokens = try container.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0
        outputTokens = try container.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
        cachedTokens = try container.decodeIfPresent(Int.self, forKey: .cachedTokens) ?? 0
        cacheWriteTokens = try container.decodeIfPresent(Int.self, forKey: .cacheWriteTokens) ?? 0
        reasoningTokens = try container.decodeIfPresent(Int.self, forKey: .reasoningTokens) ?? 0
        totalTokens = try container.decodeIfPresent(Int.self, forKey: .totalTokens) ?? 0
    }
}

/// Record-level billing is rendered for the web UI, so amounts arrive as display
/// strings such as `"$0.0726"`.
public struct CodexProxyBilling: Decodable, Equatable, Sendable {
    public let totalAmountDisplay: String?
    public let standardAmountDisplay: String?
    public let serviceTierDisplay: String?

    private enum CodingKeys: String, CodingKey {
        case totalAmountDisplay
        case standardAmountDisplay
        case serviceTierDisplay
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        totalAmountDisplay = try container.decodeIfPresent(String.self, forKey: .totalAmountDisplay)
        standardAmountDisplay = try container.decodeIfPresent(String.self, forKey: .standardAmountDisplay)
        serviceTierDisplay = try container.decodeIfPresent(String.self, forKey: .serviceTierDisplay)
    }

    /// What was actually charged for the request.
    public var cost: Double {
        CodexProxyNumber.decimal(from: totalAmountDisplay)
    }

    /// The uncached list price, used to show cache savings.
    public var standardCost: Double {
        CodexProxyNumber.decimal(from: standardAmountDisplay)
    }
}

public struct CodexProxyUsageRecordsResponse: Decodable, Sendable {
    public let items: [CodexProxyUsageRecord]
    public let currentPage: Int
    public let pageSize: Int
    public let total: Int

    private enum CodingKeys: String, CodingKey {
        case items
        case currentPage
        case pageSize
        case total
    }

    public init(items: [CodexProxyUsageRecord], currentPage: Int = 1, pageSize: Int = 0, total: Int = 0) {
        self.items = items
        self.currentPage = currentPage
        self.pageSize = pageSize
        self.total = total
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decodeIfPresent([CodexProxyUsageRecord].self, forKey: .items) ?? []
        currentPage = try container.decodeIfPresent(Int.self, forKey: .currentPage) ?? 1
        pageSize = try container.decodeIfPresent(Int.self, forKey: .pageSize) ?? items.count
        total = try container.decodeIfPresent(Int.self, forKey: .total) ?? items.count
    }
}

// MARK: - Usage Summary

/// `/api/user/usage/records/summary`. Top-level fields are display strings
/// (`"1.1K"`, `"112.6M"`, `"13.69 s"`); exact numbers live in `logicalRequests`
/// and money lives in `attempts.costs`.
public struct CodexProxyUsageSummary: Decodable, Equatable, Sendable {
    public let logicalRequests: CodexProxyRequestCounts?
    public let attempts: CodexProxyAttemptCounts?

    private enum CodingKeys: String, CodingKey {
        case logicalRequests
        case attempts
    }

    public init(logicalRequests: CodexProxyRequestCounts?, attempts: CodexProxyAttemptCounts?) {
        self.logicalRequests = logicalRequests
        self.attempts = attempts
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        logicalRequests = try container.decodeIfPresent(CodexProxyRequestCounts.self, forKey: .logicalRequests)
        attempts = try container.decodeIfPresent(CodexProxyAttemptCounts.self, forKey: .attempts)
    }

    public var requests: Int { logicalRequests?.requestCount ?? 0 }
    public var inputTokens: Int { logicalRequests?.inputTokens ?? 0 }
    public var outputTokens: Int { logicalRequests?.outputTokens ?? 0 }
    public var cachedTokens: Int { logicalRequests?.cachedTokens ?? 0 }
    public var cacheWriteTokens: Int { logicalRequests?.cacheWriteTokens ?? 0 }
    public var reasoningTokens: Int { logicalRequests?.reasoningTokens ?? 0 }
    public var totalTokens: Int { logicalRequests?.totalTokens ?? 0 }
    public var failedRequests: Int { logicalRequests?.failureCount ?? 0 }

    public var cost: Double {
        attempts?.estimatedCost ?? 0
    }
}

public struct CodexProxyRequestCounts: Decodable, Equatable, Sendable {
    public let requestCount: Int
    public let successCount: Int
    public let failureCount: Int
    public let inputTokens: Int
    public let outputTokens: Int
    public let cachedTokens: Int
    public let cacheWriteTokens: Int
    public let reasoningTokens: Int
    public let totalTokens: Int

    private enum CodingKeys: String, CodingKey {
        case requestCount
        case successCount
        case failureCount
        case inputTokens
        case outputTokens
        case cachedTokens
        case cacheWriteTokens
        case reasoningTokens
        case totalTokens
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        requestCount = try container.decodeIfPresent(Int.self, forKey: .requestCount) ?? 0
        successCount = try container.decodeIfPresent(Int.self, forKey: .successCount) ?? 0
        failureCount = try container.decodeIfPresent(Int.self, forKey: .failureCount) ?? 0
        inputTokens = try container.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0
        outputTokens = try container.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
        cachedTokens = try container.decodeIfPresent(Int.self, forKey: .cachedTokens) ?? 0
        cacheWriteTokens = try container.decodeIfPresent(Int.self, forKey: .cacheWriteTokens) ?? 0
        reasoningTokens = try container.decodeIfPresent(Int.self, forKey: .reasoningTokens) ?? 0
        totalTokens = try container.decodeIfPresent(Int.self, forKey: .totalTokens) ?? 0
    }
}

public struct CodexProxyAttemptCounts: Decodable, Equatable, Sendable {
    public let attemptCount: Int
    public let successCount: Int
    public let failureCount: Int
    public let costs: [CodexProxyCostAmount]

    private enum CodingKeys: String, CodingKey {
        case attemptCount
        case successCount
        case failureCount
        case costs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        attemptCount = try container.decodeIfPresent(Int.self, forKey: .attemptCount) ?? 0
        successCount = try container.decodeIfPresent(Int.self, forKey: .successCount) ?? 0
        failureCount = try container.decodeIfPresent(Int.self, forKey: .failureCount) ?? 0
        costs = try container.decodeIfPresent([CodexProxyCostAmount].self, forKey: .costs) ?? []
    }

    /// Sums every currency bucket; deployments in practice report a single USD entry.
    public var estimatedCost: Double {
        costs.reduce(0) { $0 + CodexProxyNumber.decimal(from: $1.estimatedAmount) }
    }
}

public struct CodexProxyCostAmount: Decodable, Equatable, Sendable {
    public let currency: String?
    public let estimatedAmount: String?

    private enum CodingKeys: String, CodingKey {
        case currency
        case estimatedAmount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        currency = try container.decodeIfPresent(String.self, forKey: .currency)
        estimatedAmount = try container.decodeIfPresent(String.self, forKey: .estimatedAmount)
    }
}

// MARK: - Usage Overview (insights)

/// `/api/user/usage/insights/overview` returns
/// `{granularity, health, performance, cost, attempts, providers}`. There is no
/// single `trend` array: request counts come from `health.points` and
/// token/cost figures from `cost.points`, joined on `bucket`.
///
/// `attempts` and `providers` are not decoded: the shared UI has no field they
/// map onto, and this provider only fills existing ones.
public struct CodexProxyUsageOverview: Decodable, Equatable, Sendable {
    public let granularity: String
    public let health: CodexProxyHealthSection?
    public let performance: CodexProxyPerformanceSection?
    public let cost: CodexProxyCostSection?

    private enum CodingKeys: String, CodingKey {
        case granularity
        case health
        case performance
        case cost
    }

    public init(
        granularity: String = "",
        health: CodexProxyHealthSection? = nil,
        performance: CodexProxyPerformanceSection? = nil,
        cost: CodexProxyCostSection? = nil
    ) {
        self.granularity = granularity
        self.health = health
        self.performance = performance
        self.cost = cost
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        granularity = try container.decodeIfPresent(String.self, forKey: .granularity) ?? ""
        health = try container.decodeIfPresent(CodexProxyHealthSection.self, forKey: .health)
        performance = try container.decodeIfPresent(CodexProxyPerformanceSection.self, forKey: .performance)
        cost = try container.decodeIfPresent(CodexProxyCostSection.self, forKey: .cost)
    }

    public var successRate: Double { health?.successRate ?? 0 }

    /// An idle window reports a successRate of 0, which must not read as 100%
    /// failures.
    public var errorRate: Double {
        guard let health, health.totalRequests > 0 else { return 0 }
        return 1 - health.successRate
    }

    public var averageLatencyMs: Double {
        performance?.latencyP50Ms ?? 0
    }

    /// Estimated tokens per request for this window, used to derive TPM. Prefer
    /// the server value; fall back to total tokens over total requests. Zero when
    /// the window is idle.
    public var tokensPerRequest: Double {
        if let value = cost?.tokensPerRequest, value > 0 { return value }
        guard let cost, let health, health.totalRequests > 0 else { return 0 }
        return Double(cost.totalTokens) / Double(health.totalRequests)
    }

    /// Merges `health.points` and `cost.points` into one series keyed by bucket.
    public var trendPoints: [CodexProxyTrendPoint] {
        let healthByBucket = Dictionary(
            (health?.points ?? []).map { ($0.bucket, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let costPoints = cost?.points ?? []

        guard !costPoints.isEmpty else {
            return (health?.points ?? []).map { point in
                CodexProxyTrendPoint(bucket: point.bucket, health: point, cost: nil)
            }
        }

        return costPoints.map { point in
            CodexProxyTrendPoint(bucket: point.bucket, health: healthByBucket[point.bucket], cost: point)
        }
    }
}

public struct CodexProxyHealthSection: Decodable, Equatable, Sendable {
    public let totalRequests: Int
    public let successRequests: Int
    public let failedRequests: Int
    public let successRate: Double
    public let points: [CodexProxyHealthPoint]

    private enum CodingKeys: String, CodingKey {
        case totalRequests
        case successRequests
        case failedRequests
        case successRate
        case points
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        totalRequests = try container.decodeIfPresent(Int.self, forKey: .totalRequests) ?? 0
        successRequests = try container.decodeIfPresent(Int.self, forKey: .successRequests) ?? 0
        failedRequests = try container.decodeIfPresent(Int.self, forKey: .failedRequests) ?? 0
        successRate = try container.decodeIfPresent(Double.self, forKey: .successRate) ?? 0
        points = try container.decodeIfPresent([CodexProxyHealthPoint].self, forKey: .points) ?? []
    }
}

public struct CodexProxyHealthPoint: Decodable, Equatable, Sendable {
    public let bucket: String
    public let totalRequests: Int
    public let successRequests: Int
    public let failedRequests: Int
    public let errorRate: Double

    private enum CodingKeys: String, CodingKey {
        case bucket
        case totalRequests
        case successRequests
        case failedRequests
        case errorRate
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bucket = try container.decode(String.self, forKey: .bucket)
        totalRequests = try container.decodeIfPresent(Int.self, forKey: .totalRequests) ?? 0
        successRequests = try container.decodeIfPresent(Int.self, forKey: .successRequests) ?? 0
        failedRequests = try container.decodeIfPresent(Int.self, forKey: .failedRequests) ?? 0
        errorRate = try container.decodeIfPresent(Double.self, forKey: .errorRate) ?? 0
    }
}

public struct CodexProxyPerformanceSection: Decodable, Equatable, Sendable {
    public let latencyP50Ms: Double
    public let latencyP95Ms: Double
    public let firstTokenP50Ms: Double

    private enum CodingKeys: String, CodingKey {
        case latencyP50Ms
        case latencyP95Ms
        case firstTokenP50Ms
    }

    public init(latencyP50Ms: Double = 0, latencyP95Ms: Double = 0, firstTokenP50Ms: Double = 0) {
        self.latencyP50Ms = latencyP50Ms
        self.latencyP95Ms = latencyP95Ms
        self.firstTokenP50Ms = firstTokenP50Ms
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        latencyP50Ms = try container.decodeIfPresent(Double.self, forKey: .latencyP50Ms) ?? 0
        latencyP95Ms = try container.decodeIfPresent(Double.self, forKey: .latencyP95Ms) ?? 0
        firstTokenP50Ms = try container.decodeIfPresent(Double.self, forKey: .firstTokenP50Ms) ?? 0
    }
}

public struct CodexProxyCostSection: Decodable, Equatable, Sendable {
    public let estimatedCost: String?
    public let standardCost: String?
    public let cacheSavings: String?
    public let inputTokens: Int
    public let outputTokens: Int
    public let cachedTokens: Int
    public let totalTokens: Int
    public let tokensPerRequest: Double?  // May be null; we compute a fallback later
    public let points: [CodexProxyCostPoint]

    private enum CodingKeys: String, CodingKey {
        case estimatedCost
        case standardCost
        case cacheSavings
        case inputTokens
        case outputTokens
        case cachedTokens
        case totalTokens
        case tokensPerRequest
        case points
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        estimatedCost = try container.decodeIfPresent(String.self, forKey: .estimatedCost)
        standardCost = try container.decodeIfPresent(String.self, forKey: .standardCost)
        cacheSavings = try container.decodeIfPresent(String.self, forKey: .cacheSavings)
        inputTokens = try container.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0
        outputTokens = try container.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
        cachedTokens = try container.decodeIfPresent(Int.self, forKey: .cachedTokens) ?? 0
        totalTokens = try container.decodeIfPresent(Int.self, forKey: .totalTokens) ?? 0
        tokensPerRequest = try container.decodeIfPresent(Double.self, forKey: .tokensPerRequest)
        points = try container.decodeIfPresent([CodexProxyCostPoint].self, forKey: .points) ?? []
    }

    public var cost: Double { CodexProxyNumber.decimal(from: estimatedCost) }
    public var standard: Double { CodexProxyNumber.decimal(from: standardCost) }
    public var savings: Double { CodexProxyNumber.decimal(from: cacheSavings) }
}

public struct CodexProxyCostPoint: Decodable, Equatable, Sendable {
    public let bucket: String
    public let inputTokens: Int
    public let outputTokens: Int
    public let cachedTokens: Int
    public let totalTokens: Int
    public let estimatedCost: String?
    public let standardCost: String?
    public let cacheWriteTokens: Int

    private enum CodingKeys: String, CodingKey {
        case bucket
        case inputTokens
        case outputTokens
        case cachedTokens
        case totalTokens
        case estimatedCost
        case standardCost
        case cacheWriteTokens
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bucket = try container.decode(String.self, forKey: .bucket)
        inputTokens = try container.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0
        outputTokens = try container.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
        cachedTokens = try container.decodeIfPresent(Int.self, forKey: .cachedTokens) ?? 0
        totalTokens = try container.decodeIfPresent(Int.self, forKey: .totalTokens) ?? 0
        estimatedCost = try container.decodeIfPresent(String.self, forKey: .estimatedCost)
        standardCost = try container.decodeIfPresent(String.self, forKey: .standardCost)
        cacheWriteTokens = try container.decodeIfPresent(Int.self, forKey: .cacheWriteTokens) ?? 0
    }
}

/// One merged bucket of the overview series.
public struct CodexProxyTrendPoint: Equatable, Sendable {
    public let bucket: String
    public let requests: Int
    public let inputTokens: Int
    public let outputTokens: Int
    public let cachedTokens: Int
    public let cacheWriteTokens: Int
    public let totalTokens: Int
    public let cost: Double
    public let standardCost: Double

    public init(bucket: String, health: CodexProxyHealthPoint?, cost: CodexProxyCostPoint?) {
        self.bucket = bucket
        self.requests = health?.totalRequests ?? 0
        self.inputTokens = cost?.inputTokens ?? 0
        self.outputTokens = cost?.outputTokens ?? 0
        self.cachedTokens = cost?.cachedTokens ?? 0
        self.cacheWriteTokens = cost?.cacheWriteTokens ?? 0
        self.totalTokens = cost?.totalTokens ?? 0
        self.cost = CodexProxyNumber.decimal(from: cost?.estimatedCost)
        self.standardCost = CodexProxyNumber.decimal(from: cost?.standardCost)
    }
}

// MARK: - Usage Diagnostics

/// `/api/user/usage/insights/diagnostics?dimension=model|provider`.
///
/// This is the only server-side per-model aggregation available: the records
/// endpoint caps `pageSize` at 100, so aggregating a week of traffic client side
/// would mean a dozen large requests on every refresh.
public struct CodexProxyDiagnosticsResponse: Decodable, Equatable, Sendable {
    public let dimension: String
    public let items: [CodexProxyDiagnosticsItem]

    private enum CodingKeys: String, CodingKey {
        case dimension
        case items
    }

    public init(dimension: String = "", items: [CodexProxyDiagnosticsItem] = []) {
        self.dimension = dimension
        self.items = items
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dimension = try container.decodeIfPresent(String.self, forKey: .dimension) ?? ""
        items = try container.decodeIfPresent([CodexProxyDiagnosticsItem].self, forKey: .items) ?? []
    }
}

public struct CodexProxyDiagnosticsItem: Decodable, Equatable, Sendable {
    public let key: String
    public let name: String
    public let requestCount: Int
    public let successCount: Int
    public let errorCount: Int
    public let errorRate: Double
    public let requestShare: Double
    public let averageLatencyMs: Double
    public let estimatedCost: String?
    public let attemptCount: Int
    public let totalTokens: Int

    private enum CodingKeys: String, CodingKey {
        case key
        case name
        case requestCount
        case successCount
        case errorCount
        case errorRate
        case requestShare
        case averageLatencyMs
        case estimatedCost
        case attemptCount
        case totalTokens
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decodeIfPresent(String.self, forKey: .key) ?? ""
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? key
        requestCount = try container.decodeIfPresent(Int.self, forKey: .requestCount) ?? 0
        successCount = try container.decodeIfPresent(Int.self, forKey: .successCount) ?? 0
        errorCount = try container.decodeIfPresent(Int.self, forKey: .errorCount) ?? 0
        errorRate = try container.decodeIfPresent(Double.self, forKey: .errorRate) ?? 0
        requestShare = try container.decodeIfPresent(Double.self, forKey: .requestShare) ?? 0
        averageLatencyMs = try container.decodeIfPresent(Double.self, forKey: .averageLatencyMs) ?? 0
        estimatedCost = try container.decodeIfPresent(String.self, forKey: .estimatedCost)
        attemptCount = try container.decodeIfPresent(Int.self, forKey: .attemptCount) ?? 0
        totalTokens = try container.decodeIfPresent(Int.self, forKey: .totalTokens) ?? 0
    }

    public var cost: Double { CodexProxyNumber.decimal(from: estimatedCost) }
}

// MARK: - Real-time Statistics

/// `/api/user/request-usage` returns an array with one entry per user.
public struct CodexProxyRequestUsage: Decodable, Equatable, Sendable {
    public let id: String?
    public let currentConcurrency: Int
    public let currentRpm: Int

    private enum CodingKeys: String, CodingKey {
        case id
        case currentConcurrency
        case currentRpm
    }

    public init(id: String? = nil, currentConcurrency: Int = 0, currentRpm: Int = 0) {
        self.id = id
        self.currentConcurrency = currentConcurrency
        self.currentRpm = currentRpm
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        currentConcurrency = try container.decodeIfPresent(Int.self, forKey: .currentConcurrency) ?? 0
        currentRpm = try container.decodeIfPresent(Int.self, forKey: .currentRpm) ?? 0
    }
}

public extension Array where Element == CodexProxyRequestUsage {
    /// Picks the entry for `userID`, falling back to the first (single-user
    /// deployments only ever return one).
    func entry(for userID: String?) -> CodexProxyRequestUsage {
        if let userID, let match = first(where: { $0.id == userID }) {
            return match
        }
        return first ?? CodexProxyRequestUsage()
    }
}

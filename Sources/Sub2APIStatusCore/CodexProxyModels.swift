import Foundation

// MARK: - CodexProxy Error

public enum CodexProxyError: Error, LocalizedError, Equatable, Sendable {
    case api(code: Int, message: String)
    case missingData
    case invalidBaseURL
    case badStatus(Int, String)

    public var errorDescription: String? {
        switch self {
        case let .api(code, message):
            "API \(code): \(message)"
        case .missingData:
            "Response did not include data."
        case .invalidBaseURL:
            "Base URL is invalid."
        case let .badStatus(status, message):
            "HTTP \(status): \(message)"
        }
    }

    public var isUnauthorized: Bool {
        switch self {
        case let .badStatus(status, _):
            status == 401
        default:
            false
        }
    }
}

// MARK: - CodexProxy Envelope

public struct CodexProxyEnvelope<Value: Decodable & Sendable>: Decodable, Sendable {
    public let code: Int
    public let message: String
    public let data: Value?

    public func value() throws -> Value {
        guard code == 0 else {
            throw CodexProxyError.api(code: code, message: message)
        }
        guard let data else {
            throw CodexProxyError.missingData
        }
        return data
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

public struct CodexProxyAuthResponse: Decodable, Sendable {
    public let role: String  // "admin" or "user"
    public let expiresAt: String
}

public struct CodexProxyAuthStatusResponse: Decodable, Sendable {
    public let authenticated: Bool
    public let session: CodexProxyAuthResponse?
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
        username = try container.decode(String.self, forKey: .username)
        role = try container.decode(String.self, forKey: .role)
        enabled = try container.decode(Bool.self, forKey: .enabled)
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
        Double(dailyLimitUsd) ?? 0
    }

    public var weeklyLimit: Double {
        Double(weeklyLimitUsd) ?? 0
    }

    public var dailyUsed: Double {
        Double(dailyUsedUsd) ?? 0
    }

    public var weeklyUsed: Double {
        Double(weeklyUsedUsd) ?? 0
    }

    public var dailyRemaining: Double? {
        guard let remaining = dailyRemainingUsd else { return nil }
        return Double(remaining)
    }

    public var weeklyRemaining: Double? {
        guard let remaining = weeklyRemainingUsd else { return nil }
        return Double(remaining)
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

    public init(id: String, name: String, color: String) {
        self.id = id
        self.name = name
        self.color = color
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
        case maxConcurrency
        case requestsPerMinute
        case routingScope
        case groups
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        prefix = try container.decode(String.self, forKey: .prefix)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        createdAt = try container.decode(String.self, forKey: .createdAt)
        lastUsedAt = try container.decodeIfPresent(String.self, forKey: .lastUsedAt)
        dailyLimitUsd = try container.decodeIfPresent(String.self, forKey: .dailyLimitUsd) ?? "0"
        weeklyLimitUsd = try container.decodeIfPresent(String.self, forKey: .weeklyLimitUsd) ?? "0"
        maxConcurrency = try container.decodeIfPresent(Int.self, forKey: .maxConcurrency) ?? 0
        requestsPerMinute = try container.decodeIfPresent(Int.self, forKey: .requestsPerMinute) ?? 0
        routingScope = try container.decodeIfPresent(String.self, forKey: .routingScope) ?? "inherit"
        groups = try container.decodeIfPresent([CodexProxyGroup].self, forKey: .groups) ?? []
    }
}

public struct CodexProxyClientKeysResponse: Decodable, Sendable {
    public let items: [CodexProxyClientKey]
    public let cursor: String?

    public init(items: [CodexProxyClientKey], cursor: String? = nil) {
        self.items = items
        self.cursor = cursor
    }
}

// MARK: - Usage Statistics

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
        createdAt = try container.decode(String.self, forKey: .createdAt)
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

public struct CodexProxyBilling: Decodable, Equatable, Sendable {
    public let costUsd: String?
    public let actualCostUsd: String?
    public let cacheSavingsUsd: String?
    public let serviceTier: String?

    private enum CodingKeys: String, CodingKey {
        case costUsd
        case actualCostUsd
        case cacheSavingsUsd
        case serviceTier
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        costUsd = try container.decodeIfPresent(String.self, forKey: .costUsd)
        actualCostUsd = try container.decodeIfPresent(String.self, forKey: .actualCostUsd)
        cacheSavingsUsd = try container.decodeIfPresent(String.self, forKey: .cacheSavingsUsd)
        serviceTier = try container.decodeIfPresent(String.self, forKey: .serviceTier)
    }

    public var cost: Double {
        guard let costUsd else { return 0 }
        return Double(costUsd) ?? 0
    }

    public var actualCost: Double {
        guard let actualCostUsd else { return 0 }
        return Double(actualCostUsd) ?? 0
    }
}

public struct CodexProxyUsageRecordsResponse: Decodable, Sendable {
    public let items: [CodexProxyUsageRecord]
    public let currentPage: Int
    public let pageSize: Int
    public let total: Int

    public init(items: [CodexProxyUsageRecord], currentPage: Int, pageSize: Int, total: Int) {
        self.items = items
        self.currentPage = currentPage
        self.pageSize = pageSize
        self.total = total
    }
}

// MARK: - Usage Summary

public struct CodexProxyUsageSummary: Decodable, Equatable, Sendable {
    public let requests: Int
    public let inputTokens: Int
    public let outputTokens: Int
    public let cachedTokens: Int
    public let cacheWriteTokens: Int
    public let reasoningTokens: Int
    public let totalTokens: Int
    public let costUsd: String?

    private enum CodingKeys: String, CodingKey {
        case requests
        case inputTokens
        case outputTokens
        case cachedTokens
        case cacheWriteTokens
        case reasoningTokens
        case totalTokens
        case costUsd
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        requests = try container.decodeIfPresent(Int.self, forKey: .requests) ?? 0
        inputTokens = try container.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0
        outputTokens = try container.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
        cachedTokens = try container.decodeIfPresent(Int.self, forKey: .cachedTokens) ?? 0
        cacheWriteTokens = try container.decodeIfPresent(Int.self, forKey: .cacheWriteTokens) ?? 0
        reasoningTokens = try container.decodeIfPresent(Int.self, forKey: .reasoningTokens) ?? 0
        totalTokens = try container.decodeIfPresent(Int.self, forKey: .totalTokens) ?? 0
        costUsd = try container.decodeIfPresent(String.self, forKey: .costUsd)
    }

    public var cost: Double {
        guard let costUsd else { return 0 }
        return Double(costUsd) ?? 0
    }
}

// MARK: - Usage Overview (with trend)

public struct CodexProxyUsageOverview: Decodable, Equatable, Sendable {
    public let summary: CodexProxyUsageSummary
    public let trend: [CodexProxyTrendPoint]
    public let costEfficiency: CodexProxyCostEfficiency?

    public init(summary: CodexProxyUsageSummary, trend: [CodexProxyTrendPoint], costEfficiency: CodexProxyCostEfficiency?) {
        self.summary = summary
        self.trend = trend
        self.costEfficiency = costEfficiency
    }
}

public struct CodexProxyTrendPoint: Decodable, Equatable, Sendable {
    public let time: String
    public let bucketSeconds: Int
    public let requests: Int
    public let inputTokens: Int
    public let outputTokens: Int
    public let cachedTokens: Int
    public let cacheWriteTokens: Int
    public let reasoningTokens: Int
    public let totalTokens: Int
    public let costUsd: String?

    private enum CodingKeys: String, CodingKey {
        case time
        case bucketSeconds
        case requests
        case inputTokens
        case outputTokens
        case cachedTokens
        case cacheWriteTokens
        case reasoningTokens
        case totalTokens
        case costUsd
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        time = try container.decode(String.self, forKey: .time)
        bucketSeconds = try container.decodeIfPresent(Int.self, forKey: .bucketSeconds) ?? 3600
        requests = try container.decodeIfPresent(Int.self, forKey: .requests) ?? 0
        inputTokens = try container.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0
        outputTokens = try container.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
        cachedTokens = try container.decodeIfPresent(Int.self, forKey: .cachedTokens) ?? 0
        cacheWriteTokens = try container.decodeIfPresent(Int.self, forKey: .cacheWriteTokens) ?? 0
        reasoningTokens = try container.decodeIfPresent(Int.self, forKey: .reasoningTokens) ?? 0
        totalTokens = try container.decodeIfPresent(Int.self, forKey: .totalTokens) ?? 0
        costUsd = try container.decodeIfPresent(String.self, forKey: .costUsd)
    }

    public var cost: Double {
        guard let costUsd else { return 0 }
        return Double(costUsd) ?? 0
    }
}

public struct CodexProxyCostEfficiency: Decodable, Equatable, Sendable {
    public let actualCostUsd: String?
    public let cacheSavingsUsd: String?
    public let serviceTierPremiumUsd: String?
    public let costPerSuccessRequest: String?
    public let costCoverage: Double?

    private enum CodingKeys: String, CodingKey {
        case actualCostUsd
        case cacheSavingsUsd
        case serviceTierPremiumUsd
        case costPerSuccessRequest
        case costCoverage
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        actualCostUsd = try container.decodeIfPresent(String.self, forKey: .actualCostUsd)
        cacheSavingsUsd = try container.decodeIfPresent(String.self, forKey: .cacheSavingsUsd)
        serviceTierPremiumUsd = try container.decodeIfPresent(String.self, forKey: .serviceTierPremiumUsd)
        costPerSuccessRequest = try container.decodeIfPresent(String.self, forKey: .costPerSuccessRequest)
        costCoverage = try container.decodeIfPresent(Double.self, forKey: .costCoverage)
    }
}

// MARK: - Real-time Statistics

public struct CodexProxyRequestUsage: Decodable, Equatable, Sendable {
    public let currentConcurrency: Int?
    public let currentRpm: Int?

    public init(currentConcurrency: Int?, currentRpm: Int?) {
        self.currentConcurrency = currentConcurrency
        self.currentRpm = currentRpm
    }
}

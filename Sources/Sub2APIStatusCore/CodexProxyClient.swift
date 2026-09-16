import Foundation

public struct CodexProxyClient: Sendable {
    public var config: AppConfig
    public var session: URLSession

    public init(config: AppConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    // MARK: - Authentication

    /// Login with username and password (for user role)
    public func login(username: String, password: String) async throws -> CodexProxyAuthResponse {
        try await post("/api/admin/auth/login", body: CodexProxyLoginRequest(username: username, password: password))
    }

    /// Get current authentication status
    public func authStatus() async throws -> CodexProxyAuthStatusResponse {
        try await get("/api/admin/auth/status")
    }

    /// Logout and clear session
    public func logout() async throws -> CodexProxyAuthResponse {
        try await post("/api/admin/auth/logout", body: EmptyBody())
    }

    // MARK: - User Profile

    /// Get current user profile (requires user role)
    public func userProfile() async throws -> CodexProxyUserProfile {
        try await get("/api/user/profile")
    }

    /// Change user password
    public func changePassword(currentPassword: String, newPassword: String) async throws -> CodexProxyAuthResponse {
        struct PasswordChangeRequest: Encodable, Sendable {
            let currentPassword: String
            let newPassword: String
        }
        return try await post("/api/user/password", body: PasswordChangeRequest(currentPassword: currentPassword, newPassword: newPassword))
    }

    // MARK: - Client Keys

    /// Get user's client keys
    public func clientKeys(cursor: String? = nil, limit: Int = 50) async throws -> CodexProxyClientKeysResponse {
        var query: [URLQueryItem] = []
        if let cursor {
            query.append(URLQueryItem(name: "cursor", value: cursor))
        }
        query.append(URLQueryItem(name: "limit", value: String(limit)))
        return try await get("/api/user/client-keys", query: query)
    }

    /// Get a specific client key by ID
    public func clientKey(id: String) async throws -> CodexProxyClientKey {
        try await get("/api/user/client-keys/\(id)")
    }

    /// Reveal the full API key (sensitive operation)
    public func revealClientKey(id: String) async throws -> CodexProxyClientKey {
        try await get("/api/user/client-keys/reveal?id=\(id)")
    }

    /// Create a new client key
    public func createClientKey(
        name: String,
        label: String? = nil,
        customKey: String? = nil,
        groupIds: [String],
        maxConcurrency: Int = 0,
        requestsPerMinute: Int = 0,
        dailyLimitUsd: String? = nil,
        weeklyLimitUsd: String? = nil
    ) async throws -> CodexProxyClientKey {
        struct CreateKeyRequest: Encodable, Sendable {
            let name: String
            let label: String?
            let customKey: String?
            let groupIds: [String]
            let maxConcurrency: Int
            let requestsPerMinute: Int
            let dailyLimitUsd: String?
            let weeklyLimitUsd: String?
        }

        let request = CreateKeyRequest(
            name: name,
            label: label,
            customKey: customKey,
            groupIds: groupIds,
            maxConcurrency: maxConcurrency,
            requestsPerMinute: requestsPerMinute,
            dailyLimitUsd: dailyLimitUsd,
            weeklyLimitUsd: weeklyLimitUsd
        )

        return try await post("/api/user/client-keys/create", body: request)
    }

    /// Update client key (only name and label can be updated by user)
    public func updateClientKey(id: String, name: String, label: String? = nil) async throws -> CodexProxyClientKey {
        struct UpdateKeyRequest: Encodable, Sendable {
            let id: String
            let name: String
            let label: String?
        }

        return try await post("/api/user/client-keys/update", body: UpdateKeyRequest(id: id, name: name, label: label))
    }

    /// Enable a client key
    public func enableClientKey(id: String) async throws -> CodexProxyClientKey {
        struct EnableRequest: Encodable, Sendable {
            let id: String
        }
        return try await post("/api/user/client-keys/enable", body: EnableRequest(id: id))
    }

    /// Disable a client key
    public func disableClientKey(id: String) async throws -> CodexProxyClientKey {
        struct DisableRequest: Encodable, Sendable {
            let id: String
        }
        return try await post("/api/user/client-keys/disable", body: DisableRequest(id: id))
    }

    /// Delete a client key
    public func deleteClientKey(id: String) async throws -> CodexProxyAuthResponse {
        struct DeleteRequest: Encodable, Sendable {
            let id: String
        }
        return try await post("/api/user/client-keys/delete", body: DeleteRequest(id: id))
    }

    // MARK: - Usage Statistics

    /// Get usage records (detailed)
    public func usageRecords(
        startTime: Date,
        endTime: Date,
        currentPage: Int = 1,
        pageSize: Int = 50,
        provider: String? = nil,
        model: String? = nil,
        statusCode: Int? = nil,
        search: String? = nil
    ) async throws -> CodexProxyUsageRecordsResponse {
        let formatter = ISO8601DateFormatter()
        var query: [URLQueryItem] = [
            URLQueryItem(name: "startTime", value: formatter.string(from: startTime)),
            URLQueryItem(name: "endTime", value: formatter.string(from: endTime)),
            URLQueryItem(name: "currentPage", value: String(currentPage)),
            URLQueryItem(name: "pageSize", value: String(pageSize)),
        ]

        if let provider {
            query.append(URLQueryItem(name: "provider", value: provider))
        }
        if let model {
            query.append(URLQueryItem(name: "model", value: model))
        }
        if let statusCode {
            query.append(URLQueryItem(name: "statusCode", value: String(statusCode)))
        }
        if let search {
            query.append(URLQueryItem(name: "search", value: search))
        }

        return try await get("/api/user/usage/records", query: query)
    }

    /// Get usage summary (aggregated)
    public func usageSummary(startTime: Date, endTime: Date) async throws -> CodexProxyUsageSummary {
        let formatter = ISO8601DateFormatter()
        let query: [URLQueryItem] = [
            URLQueryItem(name: "startTime", value: formatter.string(from: startTime)),
            URLQueryItem(name: "endTime", value: formatter.string(from: endTime)),
        ]
        return try await get("/api/user/usage/records/summary", query: query)
    }

    /// Get usage overview with trend and insights
    public func usageOverview(startTime: Date, endTime: Date) async throws -> CodexProxyUsageOverview {
        let formatter = ISO8601DateFormatter()
        let query: [URLQueryItem] = [
            URLQueryItem(name: "startTime", value: formatter.string(from: startTime)),
            URLQueryItem(name: "endTime", value: formatter.string(from: endTime)),
        ]
        return try await get("/api/user/usage/insights/overview", query: query)
    }

    /// Get usage diagnostics
    public func usageDiagnostics(
        startTime: Date,
        endTime: Date,
        dimension: String = "model"
    ) async throws -> CodexProxyUsageOverview {
        let formatter = ISO8601DateFormatter()
        let query: [URLQueryItem] = [
            URLQueryItem(name: "startTime", value: formatter.string(from: startTime)),
            URLQueryItem(name: "endTime", value: formatter.string(from: endTime)),
            URLQueryItem(name: "dimension", value: dimension),
        ]
        return try await get("/api/user/usage/insights/diagnostics", query: query)
    }

    /// Get real-time request usage (concurrency and RPM)
    public func requestUsage() async throws -> CodexProxyRequestUsage {
        try await get("/api/user/request-usage")
    }

    // MARK: - HTTP Methods

    public func get<Value: Decodable & Sendable>(_ path: String, query: [URLQueryItem] = []) async throws -> Value {
        var request = try makeRequest(path: path, query: query)
        request.httpMethod = "GET"
        return try await send(request)
    }

    public func post<Body: Encodable & Sendable, Value: Decodable & Sendable>(_ path: String, body: Body) async throws -> Value {
        var request = try makeRequest(path: path)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder.codexProxy.encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await send(request)
    }

    private func makeRequest(path: String, query: [URLQueryItem] = []) throws -> URLRequest {
        guard let baseURL = config.apiBaseURL else {
            throw CodexProxyError.invalidBaseURL
        }

        let cleanPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        var components = URLComponents(url: baseURL.appending(path: cleanPath), resolvingAgainstBaseURL: false)
        components?.queryItems = query.isEmpty ? nil : query

        guard let url = components?.url else {
            throw CodexProxyError.invalidBaseURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if !config.authToken.isEmpty {
            request.setValue("cpr_admin_session=\(config.authToken)", forHTTPHeaderField: "Cookie")
        }
        return request
    }

    private func send<Value: Decodable & Sendable>(_ request: URLRequest) async throws -> Value {
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let message = String(data: data, encoding: .utf8) ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw CodexProxyError.badStatus(http.statusCode, message)
        }

        let decoder = JSONDecoder.codexProxy
        if let envelope = try? decoder.decode(CodexProxyEnvelope<Value>.self, from: data) {
            return try envelope.value()
        }
        return try decoder.decode(Value.self, from: data)
    }
}

// MARK: - Helper Types

private struct EmptyBody: Encodable, Sendable {}

// MARK: - JSON Coding Extensions

extension JSONEncoder {
    static let codexProxy: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

extension JSONDecoder {
    static let codexProxy: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

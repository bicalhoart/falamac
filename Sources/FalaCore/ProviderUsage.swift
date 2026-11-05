import Foundation

public struct ProviderUsage: Decodable, Sendable {
    public let usage: Double?
    public let usageDaily: Double?
    public let usageWeekly: Double?
    public let usageMonthly: Double?
    public let limit: Double?
    public let limitRemaining: Double?

    public static func decode(_ data: Data) throws -> ProviderUsage {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let result = try decoder.decode(Envelope.self, from: data).data
        guard result.usage != nil || result.usageDaily != nil || result.usageMonthly != nil else { throw APIError.invalidResponse }
        for value in [result.usage, result.usageDaily, result.usageWeekly, result.usageMonthly, result.limit] {
            if let value, !value.isFinite || value < 0 { throw APIError.invalidResponse }
        }
        if let remaining = result.limitRemaining, !remaining.isFinite { throw APIError.invalidResponse }
        return result
    }
    private struct Envelope: Decodable { let data: ProviderUsage }
}

public enum ProviderUsageClient {
    public static func request(key: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/key")!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "GET"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        return request
    }

    public static func fetch(key: String, session: URLSession? = nil) async throws -> ProviderUsage {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil
        let client = session ?? URLSession(configuration: config)
        defer { if session == nil { client.finishTasksAndInvalidate() } }
        let (data, response) = try await client.data(for: request(key: key))
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw APIError.http(http.statusCode, "OpenRouter") }
        return try ProviderUsage.decode(data)
    }
}

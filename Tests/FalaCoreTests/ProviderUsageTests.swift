import Testing
import Foundation
@testable import FalaCore

struct ProviderUsageTests {
    @Test func decodesActualUsageWithoutConfusingKeyQuotaWithAccountBalance() throws {
        let data = Data(#"{"data":{"usage":1.5,"usage_daily":0.01,"usage_weekly":0.1,"usage_monthly":0.4,"limit":5,"limit_remaining":3.5,"label":"ignored"}}"#.utf8)
        let result = try ProviderUsage.decode(data)
        #expect(result.usageMonthly == 0.4)
        #expect(result.usageDaily == 0.01)
        #expect(result.limitRemaining == 3.5)
    }

    @Test func missingOrUnlimitedFieldsRemainUnknownInsteadOfZero() throws {
        let result = try ProviderUsage.decode(Data(#"{"data":{"usage":0,"limit":null,"limit_remaining":null}}"#.utf8))
        #expect(result.usage == 0)
        #expect(result.usageDaily == nil)
        #expect(result.limit == nil)
        #expect(result.limitRemaining == nil)
        #expect(throws: APIError.self) {
            try ProviderUsage.decode(Data(#"{"data":{"usage":-1}}"#.utf8))
        }
    }

    @Test func usageQueryIsReadOnlyAndDoesNotPutKeyInURL() {
        let request = ProviderUsageClient.request(key: "test-placeholder")
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://openrouter.ai/api/v1/key")
        #expect(request.httpBody == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-placeholder")
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
    }
}

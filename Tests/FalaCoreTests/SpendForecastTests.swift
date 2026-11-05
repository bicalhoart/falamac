import Testing
import Foundation
@testable import FalaCore

struct SpendForecastTests {
    private func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }
    private func usage(monthly: Double?, daily: Double?) throws -> ProviderUsage {
        var values: [String: Any] = ["usage": monthly ?? 0]
        if let monthly { values["usage_monthly"] = monthly }
        if let daily { values["usage_daily"] = daily }
        return try ProviderUsage.decode(JSONSerialization.data(withJSONObject: ["data": values]))
    }
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func firstUseDayDoesNotIncludeEarlierZeroDaysOrGroqEstimates() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try SpendForecastStore(directory: dir)
        let value = try #require(try store.observe(usage(monthly: 0.02, daily: 0.02), key: "test-key", now: date("2026-11-05T22:00:00Z")))
        #expect(value.sampledDays == 1)
        #expect(value.remainingDays == 25)
        #expect(abs(value.dailyAverage - 0.02) < 0.000000001)
        #expect(abs(value.projectedAdditional - 0.5) < 0.000000001)
        #expect(abs(value.projectedTotal - 0.52) < 0.000000001)
    }

    @Test func persistsStartAndCountsDaysWithoutRequests() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        _ = try SpendForecastStore(directory: dir).observe(usage(monthly: 0.02, daily: 0.02), key: "test-key", now: date("2026-11-05T22:00:00Z"))
        let value = try #require(try SpendForecastStore(directory: dir).observe(usage(monthly: 0.06, daily: 0.01), key: "test-key", now: date("2026-11-07T00:01:00Z")))
        #expect(value.sampledDays == 3)
        #expect(value.remainingDays == 23)
        #expect(abs(value.projectedTotal - 0.52) < 0.000000001)
    }

    @Test func unknownEarlierUsageUsesElapsedCalendarDays() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let value = try #require(try SpendForecastStore(directory: dir).observe(usage(monthly: 10, daily: 2), key: "test-key", now: date("2026-11-05T23:59:59Z")))
        #expect(value.sampledDays == 5)
        #expect(value.projectedTotal == 60)
    }

    @Test func keyChangeResetsSamplingAndDoesNotStoreCredentials() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try SpendForecastStore(directory: dir)
        _ = try store.observe(usage(monthly: 1, daily: 1), key: "old-test-key", now: date("2026-11-01T00:01:00Z"))
        let value = try #require(try store.observe(usage(monthly: 0.2, daily: 0.2), key: "new-test-key", now: date("2026-11-05T22:00:00Z")))
        #expect(value.sampledDays == 1)
        let file = dir.appendingPathComponent("openrouter-forecast.json")
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(!text.contains("new-test-key"))
        #expect(!text.contains("old-test-key"))
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
    }

    @Test func utcMonthRolloverAndLeapYearHaveNoRemainingDayOffByOne() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try SpendForecastStore(directory: dir)
        let end = try #require(try store.observe(usage(monthly: 29, daily: 1), key: "test-key", now: date("2028-02-29T23:59:59Z")))
        #expect(end.sampledDays == 29)
        #expect(end.remainingDays == 0)
        #expect(end.projectedTotal == 29)
        let next = try #require(try store.observe(usage(monthly: 0.1, daily: 0.1), key: "test-key", now: date("2028-03-01T00:00:01Z")))
        #expect(next.sampledDays == 1)
        #expect(next.remainingDays == 30)
        #expect(abs(next.projectedTotal - 3.1) < 0.000000001)
    }

    @Test func missingMonthlySpendDoesNotPretendItIsZero() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try SpendForecastStore(directory: dir).observe(usage(monthly: nil, daily: nil), key: "test-key") == nil)
    }
}

import Foundation
import CryptoKit

public struct SpendForecast: Sendable {
    public let dailyAverage: Double
    public let projectedAdditional: Double
    public let projectedTotal: Double
    public let sampledDays: Int
    public let remainingDays: Int
}

/// Stores only the current key's month and first-use day; never credentials or transcripts.
public final class SpendForecastStore {
    private struct Tracking: Codable {
        let keyHash: String
        let month: Date
        let firstDay: Date
        let lastDay: Date
        let lastSpend: Double
    }
    private var tracking: Tracking?
    private let file: URL
    private static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    public init(directory: URL) throws {
        file = directory.appendingPathComponent("openrouter-forecast.json")
        if FileManager.default.fileExists(atPath: file.path) {
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            if size < 4096 { tracking = try? JSONDecoder().decode(Tracking.self, from: Data(contentsOf: file)) }
        }
    }

    public func observe(_ usage: ProviderUsage, key: String, now: Date = Date()) throws -> SpendForecast? {
        guard let monthly = usage.usageMonthly, monthly.isFinite, monthly >= 0 else { return nil }
        let calendar = Self.utc
        let day = calendar.startOfDay(for: now)
        guard let month = calendar.dateInterval(of: .month, for: now),
              let nextMonth = calendar.date(byAdding: .month, value: 1, to: month.start),
              let lastDay = calendar.date(byAdding: .day, value: -1, to: nextMonth) else { return nil }
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        let firstDay: Date
        if let previous = tracking, previous.keyHash == hash, previous.month == month.start,
           previous.firstDay >= month.start, previous.firstDay <= day, previous.lastDay <= day,
           previous.lastSpend <= monthly + 0.000000001 {
            firstDay = previous.firstDay
        } else if let daily = usage.usageDaily, daily.isFinite, daily >= 0,
                  abs(monthly - daily) < 0.000000001 {
            // The provider confirms all month-to-date spend happened today.
            firstDay = day
        } else {
            // Earlier usage exists but its start is unknown: use the whole UTC month so far.
            firstDay = month.start
        }
        let sampled = (calendar.dateComponents([.day], from: firstDay, to: day).day ?? 0) + 1
        let remaining = calendar.dateComponents([.day], from: day, to: lastDay).day ?? 0
        let average = monthly / Double(sampled)
        tracking = Tracking(keyHash: hash, month: month.start, firstDay: firstDay, lastDay: day, lastSpend: monthly)
        try JSONEncoder().encode(tracking).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return SpendForecast(dailyAverage: average, projectedAdditional: average * Double(remaining),
                             projectedTotal: monthly + average * Double(remaining),
                             sampledDays: sampled, remainingDays: remaining)
    }
}

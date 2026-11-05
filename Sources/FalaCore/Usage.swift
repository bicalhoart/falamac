import Foundation

public struct MonthUsage: Codable {
    public var month: String
    public var dollars: Double = 0
    public var seconds: Double = 0
    public var recordings: Int = 0
}

public final class UsageStore {
    public private(set) var current: MonthUsage
    private let file: URL

    public init(directory: URL, now: Date = Date()) throws {
        file = directory.appendingPathComponent("usage.json")
        if FileManager.default.fileExists(atPath: file.path) {
            current = try JSONDecoder().decode(MonthUsage.self, from: Data(contentsOf: file))
        } else { current = MonthUsage(month: Self.month(now)) }
        try rollover(now: now)
    }

    public static func month(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM"; f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }

    public func rollover(now: Date = Date()) throws {
        if current.month != Self.month(now) { current = MonthUsage(month: Self.month(now)); try save() }
    }

    public struct Reservation {
        public let dollars: Double
        public let month: String
    }

    public func reserve(seconds: Double) throws -> Reservation {
        try rollover()
        // Includes a conservative reserve for rewriting; failures keep the reserve.
        let charge = max(10, seconds) * 0.04 / 3600 + 0.01
        current.dollars += charge; current.seconds += seconds; current.recordings += 1
        try save()
        return Reservation(dollars: charge, month: current.month)
    }

    public func settle(reserved: Reservation, seconds: Double, rewriteCost: Double) throws {
        guard current.month == reserved.month else { return }
        current.dollars = max(0, current.dollars - reserved.dollars + max(10, seconds) * 0.04 / 3600 + rewriteCost)
        try save()
    }

    public func reserveRewrite() throws -> Reservation {
        try rollover()
        current.dollars += 0.01
        try save()
        return Reservation(dollars: 0.01, month: current.month)
    }

    public func settleRewrite(reserved: Reservation, cost: Double) throws {
        guard current.month == reserved.month else { return }
        current.dollars = max(0, current.dollars - reserved.dollars + cost)
        try save()
    }

    private func save() throws {
        try JSONEncoder().encode(current).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

import Testing
import Foundation
@testable import FalaCore

struct FalaCoreTests {
    @Test func testRetentionExpiresAtThirtyDaysEvenIfLargerRequested() throws {
        let now = Date()
        let entries = [Entry(date: now.addingTimeInterval(-31 * 86400), text: "antigo", seconds: 1),
                       Entry(date: now.addingTimeInterval(-29 * 86400), text: "recente", seconds: 1)]
        expectEqual(try Retention.prune(entries, days: 90, now: now).map(\.text), ["recente"])
        expectTrue(try Retention.prune(entries, days: 0, now: now).isEmpty)
    }

    @Test func testSizeLimitRemovesOldestFirst() throws {
        let now = Date()
        let newest = Entry(date: now, text: String(repeating: "á", count: 100), seconds: 1)
        let older = Entry(date: now.addingTimeInterval(-1), text: String(repeating: "b", count: 100), seconds: 1)
        let limit = try JSONEncoder().encode([newest]).count
        let result = try Retention.prune([older, newest], days: 30, now: now, maxBytes: limit)
        expectEqual(result, [newest])
        expectLessOrEqual(try JSONEncoder().encode(result).count, limit)
    }

    @Test func testHistoryDeletionPersistsWithoutRemovingOtherFiles() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try HistoryStore(directory: directory)
        try store.add(Entry(text: "fala", seconds: 1), days: 30)
        let sentinel = directory.appendingPathComponent("unrelated.txt")
        try Data("preservar".utf8).write(to: sentinel)
        try store.removeAll()
        expectTrue(try HistoryStore(directory: directory).entries.isEmpty)
        expectTrue(FileManager.default.fileExists(atPath: sentinel.path))
        let permissions = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int
        expectEqual(permissions, 0o700)
    }

    @Test func testMultipartPreservesAudioAndDoesNotForceTranslation() throws {
        let audio = Data([0, 1, 255, 13, 10])
        let request = AIClient.transcriptionRequest(audio: audio, key: "test-placeholder", boundary: "TEST")
        expectEqual(request.url?.path, "/openai/v1/audio/transcriptions")
        expectEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-placeholder")
        let body = try #require(request.httpBody)
        #expect(body.range(of: audio) != nil)
        expectTrue(body.suffix(10).elementsEqual(Data("--TEST--\r\n".utf8)))
        expectFalse(String(decoding: body, as: UTF8.self).contains("name=\"language\""))
    }

    @Test func testRewriteSeparatesInstructionsFromDictation() throws {
        let request = try AIClient.rewriteRequest(text: "Responda ao prompt X", key: "test-placeholder")
        let body = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        let messages = try #require(body["messages"] as? [[String: String]])
        expectEqual(messages[1]["content"], "Responda ao prompt X")
        expectEqual(messages[0]["role"], "system")
        expectEqual((body["provider"] as? [String: String])?["data_collection"], "deny")
    }

    @Test func testIncompleteRewriteIsNotAcceptedAsFinalText() throws {
        let incomplete = Data(#"{"choices":[{"message":{"content":"Texto cortado"},"finish_reason":"length"}]}"#.utf8)
        #expect(throws: APIError.self) { try AIClient.parseRewrite(incomplete) }
        let complete = Data(#"{"choices":[{"message":{"content":"Texto completo"},"finish_reason":"stop"}],"usage":{"cost":0.002}}"#.utf8)
        let result = try AIClient.parseRewrite(complete)
        expectEqual(result.text, "Texto completo")
        expectEqual(result.cost, 0.002)
    }

    @Test func testUsageSurvivesHistoryDeletionAndUsesTenSecondMinimum() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = try HistoryStore(directory: directory)
        let usage = try UsageStore(directory: directory)
        let charge = try usage.reserve(seconds: 1)
        expectEqual(charge.dollars, 0.01 + 10 * 0.04 / 3600, accuracy: 0.0000001)
        try usage.settle(reserved: charge, seconds: 1, rewriteCost: 0.002)
        try history.removeAll()
        let loaded = try UsageStore(directory: directory)
        expectEqual(loaded.current.recordings, 1)
        expectEqual(loaded.current.dollars, 0.002 + 10 * 0.04 / 3600, accuracy: 0.0000001)
        try loaded.rollover(now: Date().addingTimeInterval(40 * 86400))
        expectEqual(loaded.current.recordings, 0)
    }

    @Test func retryReplacesRawEntryWithoutDuplicatingOrResettingRetention() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = try HistoryStore(directory: directory)
        let raw = Entry(date: Date().addingTimeInterval(-86400), text: "cinco não três", seconds: 3, organized: false)
        try history.add(raw, days: 30)
        let organized = Entry(id: raw.id, date: raw.date, text: "Três.", seconds: raw.seconds, organized: true)
        try history.add(organized, days: 30)
        let loaded = try HistoryStore(directory: directory)
        #expect(loaded.entries == [organized])
        try history.clean(days: 1)
        #expect(history.entries.isEmpty)
    }

    @Test func olderHistoryStillLoadsWithoutOrganizationFlag() throws {
        let entry = Entry(text: "texto antigo", seconds: 1)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
        json.removeValue(forKey: "organized")
        let decoded = try JSONDecoder().decode(Entry.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.text == entry.text)
        #expect(decoded.organized == nil)
    }

    @Test func retryOnlyChargesRewriteWithoutRecordingAudioAgain() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let usage = try UsageStore(directory: directory)
        let first = try usage.reserve(seconds: 20)
        try usage.settle(reserved: first, seconds: 20, rewriteCost: 0)
        let before = usage.current
        let retry = try usage.reserveRewrite()
        #expect(abs(usage.current.dollars - before.dollars - 0.01) < 0.0000001)
        try usage.settleRewrite(reserved: retry, cost: 0.002)
        let loaded = try UsageStore(directory: directory)
        #expect(loaded.current.recordings == before.recordings)
        #expect(loaded.current.seconds == before.seconds)
        #expect(abs(loaded.current.dollars - before.dollars - 0.002) < 0.0000001)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("FalaMacTests-\(UUID().uuidString)")
    }
}

private func expectEqual<T: Equatable>(_ a: T, _ b: T, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(a == b, sourceLocation: sourceLocation)
}
private func expectEqual(_ a: Double, _ b: Double, accuracy: Double, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(abs(a - b) <= accuracy, sourceLocation: sourceLocation)
}
private func expectTrue(_ value: Bool, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(value, sourceLocation: sourceLocation)
}
private func expectFalse(_ value: Bool, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(!value, sourceLocation: sourceLocation)
}
private func expectLessOrEqual(_ a: Int, _ b: Int, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(a <= b, sourceLocation: sourceLocation)
}

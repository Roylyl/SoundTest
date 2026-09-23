import XCTest
@testable import SoundTest

final class WatchLogImportTests: XCTestCase {
    func testWatchFileRequiresMatchingTransferIDAndStaysOutsideIPhoneSessions() throws {
        let id = UUID().uuidString
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let record = WatchTestLog(
            schemaVersion: 1, id: id, startedAt: start, endedAt: start.addingTimeInterval(2),
            modelID: "appleSoundAnalysisV1", modelName: "Apple Sound Analysis（系统模型）",
            device: "Apple Watch", input: "Apple Watch 麦克风", status: "completed",
            error: nil, threshold: 0.3, audioSeconds: 2, inferenceMS: nil,
            windows: [WatchWindowLog(index: 0, start: 0, end: 1,
                                     scores: [WatchRawScore(label: "cough", score: 0.8)],
                                     targets: [WatchTargetScore(name: "咳嗽", label: "cough",
                                                                score: 0.8, prompted: true)])]
        )
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
        let destination = try XCTUnwrap(WatchLogStore.url(for: id))
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }
        try JSONEncoder().encode(record).write(to: source)

        XCTAssertThrowsError(try WatchLogStore.importFile(source, expectedID: UUID().uuidString))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try WatchLogStore.importFile(source, expectedID: id), id)
        XCTAssertTrue(WatchLogStore.all().contains { $0.id == id })
        XCTAssertFalse(FileManager.default.fileExists(atPath: SoundSessionStore.url(id).path))
    }

    func testYAMNetWatchLogPreservesMeasuredInferenceAndRejectsChangedDuplicate() throws {
        let id = UUID().uuidString
        let start = Date(timeIntervalSince1970: 1_700_000_100)
        let record = WatchTestLog(
            schemaVersion: 1, id: id, startedAt: start, endedAt: start.addingTimeInterval(1),
            modelID: "yamnetCoreML", modelName: "YAMNet（Core ML）",
            device: "Apple Watch", input: "内建麦克风", status: "completed",
            error: nil, threshold: 0.3, audioSeconds: 0.975, inferenceMS: 14.2,
            windows: [WatchWindowLog(index: 1, start: 0, end: 0.975,
                                     scores: [WatchRawScore(label: "Bark", score: 0.81)],
                                     targets: [WatchTargetScore(name: "猫狗叫声", label: "Bark",
                                                                score: 0.81, prompted: true)])]
        )
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
        let destination = try XCTUnwrap(WatchLogStore.url(for: id))
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }
        try JSONEncoder().encode(record).write(to: source)
        XCTAssertEqual(try WatchLogStore.importFile(source, expectedID: id), id)
        XCTAssertEqual(WatchLogStore.all().first { $0.id == id }?.inferenceMS, 14.2)

        let changed = WatchTestLog(
            schemaVersion: 1, id: id, startedAt: start, endedAt: start.addingTimeInterval(1),
            modelID: "yamnetCoreML", modelName: "YAMNet（Core ML）",
            device: "Apple Watch", input: "内建麦克风", status: "completed",
            error: nil, threshold: 0.3, audioSeconds: 0.975, inferenceMS: 99,
            windows: record.windows
        )
        try JSONEncoder().encode(changed).write(to: source)
        XCTAssertThrowsError(try WatchLogStore.importFile(source, expectedID: id))
    }
}

import XCTest
import AVFoundation
@testable import SoundTest

/// Generated PCM checks orchestration and persistence only, not event accuracy.
final class BatchTests: XCTestCase {
    private var fixtures: URL!
    override func setUpWithError() throws {
        fixtures = FileManager.default.temporaryDirectory.appendingPathComponent("BatchTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: fixtures) }

    private func audio(_ name: String, seconds: Double = 0.2) throws -> URL {
        let path = fixtures.appendingPathComponent(name)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
        let file = try AVAudioFile(forWriting: path, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096))
        let data = try XCTUnwrap(buffer.floatChannelData)
        var remaining = Int(seconds * 16000)
        while remaining > 0 {
            let count = min(remaining, 4096); buffer.frameLength = AVAudioFrameCount(count)
            for frame in 0..<count { data[0][frame] = 0 }
            try file.write(from: buffer); remaining -= count
        }
        return path
    }
    @MainActor private func waitUntil(_ description: String, timeout: Double = 30, _ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition(), description)
        if !condition() { throw SoundError.message("Timed out: \(description)") }
    }
    @MainActor private func controller() async throws -> SoundController {
        let app = SoundController(loadInitialModel: false)
        app.selectModel(.yamnet)
        try await waitUntil("YAMNet is ready") { app.ready && app.canConfigure }
        return app
    }

    @MainActor func testMixedBatchContinuesAfterBadFileAndRerunGetsIndependentGroup() async throws {
        let first = try audio("01_same.wav"), last = try audio("03_same.wav")
        let invalid = fixtures.appendingPathComponent("02_invalid.wav")
        try Data("invalid WAV fixture".utf8).write(to: invalid)
        let app = try await controller()
        var groups: [String] = []
        defer { app.clearBatch(); for id in groups { try? BatchLogStore.delete(id) } }
        app.importBatch([last, invalid, first])
        try await waitUntil("3 files imported") { !app.preparing && app.batchFiles.count == 3 }
        XCTAssertEqual(app.batchFiles.map(\.filename), ["01_same.wav", "02_invalid.wav", "03_same.wav"])
        app.material.manualLabel = "must not be copied to every file"
        app.batchName = "Mixed batch integration"
        app.analyzeBatch()
        app.clearLogs() // Must be ignored while this round is preparing/running.
        XCTAssertFalse(app.deletingLogs)
        app.exportAllLogs { _ in XCTFail("An active batch must not export a partial log snapshot") }
        XCTAssertFalse(app.exportingLogs)
        app.selectModel(.cpMobile)
        XCTAssertEqual(app.model, .yamnet, "Model switches must stay disabled during a round")
        try await waitUntil("First round finishes") { !app.batchActive && !app.busy }
        let firstGroup = try XCTUnwrap(app.activeBatchGroup); groups.append(firstGroup.id)
        XCTAssertEqual(firstGroup.status, .completed)
        XCTAssertEqual(firstGroup.completedCount, 2); XCTAssertEqual(firstGroup.failedCount, 1)
        XCTAssertEqual(firstGroup.items[1].status, .failed)
        XCTAssertNotNil(firstGroup.items[1].error); XCTAssertNil(firstGroup.items[1].recordID)
        XCTAssertEqual(try BatchLogStore.load(firstGroup.id).items.map(\.status), [.completed, .failed, .completed])
        for index in [0, 2] {
            let record = try SoundSessionStore.load(XCTUnwrap(firstGroup.items[index].recordID))
            XCTAssertEqual(record.batch?.groupID, firstGroup.id)
            XCTAssertEqual(record.batch?.index, index); XCTAssertEqual(record.batch?.total, 3)
            XCTAssertEqual(record.batch?.itemID, firstGroup.items[index].id)
            XCTAssertEqual(record.material.filename, firstGroup.items[index].filename)
            XCTAssertEqual(record.material.inputMethod, .file); XCTAssertEqual(record.material.manualLabel, "")
            XCTAssertEqual(record.material.testCase, "批量文件")
            XCTAssertEqual(record.modelSampleRate, 16000)
            XCTAssertEqual(record.windows.first?.scores.count, 521)
            XCTAssertNil(record.windows.first?.windowCollectionSeconds)
            XCTAssertNil(record.windows.first?.queueDelayMS)
        }
        let export = try BatchLogStore.export(firstGroup.id)
        defer { try? FileManager.default.removeItem(at: export) }
        _ = try BatchLogStore.export(firstGroup.id) // A second share safely replaces its generated file.
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: export)) as? [String: Any])
        XCTAssertEqual((object["records"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual(((object["group"] as? [String: Any])?["items"] as? [[String: Any]])?.count, 3)
        XCTAssertFalse(app.batchFiles.isEmpty)
        app.selectModel(.cpMobile)
        try await waitUntil("32 kHz scene model is ready") { app.ready && app.canConfigure }
        app.analyzeBatch()
        try await waitUntil("Second round finishes") { !app.batchActive && !app.busy }
        let second = try XCTUnwrap(app.activeBatchGroup); groups.append(second.id)
        XCTAssertNotEqual(firstGroup.id, second.id); XCTAssertEqual(second.model, .cpMobile)
        XCTAssertEqual(second.completedCount, 2); XCTAssertEqual(second.failedCount, 1)
        let sceneRecord = try SoundSessionStore.load(XCTUnwrap(second.items[0].recordID))
        XCTAssertEqual(sceneRecord.modelSampleRate, 32000)
        XCTAssertEqual(sceneRecord.material.originalSampleRate, 16000)
        XCTAssertEqual(sceneRecord.windows.first?.scores.count, 10)
        XCTAssertNotNil(sceneRecord.windows.first?.scene)
        XCTAssertEqual(try BatchLogStore.load(firstGroup.id).model, .yamnet)
        app.deleteBatch(firstGroup.id)
        app.deleteBatch(firstGroup.id) // Repeated gestures cannot enqueue a second mutation.
        try await waitUntil("Deletion refreshes one consistent snapshot") { !app.deletingLogs }
        XCTAssertFalse(app.batchHistory.contains { $0.id == firstGroup.id })
        XCTAssertFalse(app.history.contains { $0.batch?.groupID == firstGroup.id })
        groups.removeAll { $0 == firstGroup.id }
        XCTAssertEqual(try BatchLogStore.load(second.id).completedCount, 2)
        XCTAssertNoThrow(try SoundSessionStore.load(XCTUnwrap(second.items[0].recordID)))
    }

    @MainActor func testStopBeforeFirstFileStillSavesAGroupWithUnrunItems() async throws {
        let app = try await controller()
        app.importBatch([try audio("a.wav"), try audio("b.wav")])
        try await waitUntil("Files imported") { !app.preparing && app.batchFiles.count == 2 }
        app.analyzeBatch(); app.stop()
        try await waitUntil("Stopped batch finalizes") { !app.batchActive && !app.busy }
        let group = try XCTUnwrap(app.activeBatchGroup)
        defer { app.clearBatch(); try? BatchLogStore.delete(group.id) }
        XCTAssertEqual(group.status, .stopped)
        XCTAssertTrue(group.items.allSatisfy { $0.status == .skipped && $0.recordID == nil })
        XCTAssertEqual(try BatchLogStore.load(group.id).items.count, 2)
    }

    @MainActor func testStopDuringAnalysisPreservesPartialRecordAndDoesNotStartNextFile() async throws {
        let app = try await controller()
        app.options.stepSeconds = 0.24
        app.importBatch([try audio("01_long.wav", seconds: 120), try audio("02_next.wav")])
        try await waitUntil("Long files imported") { !app.preparing && app.batchFiles.count == 2 }
        app.analyzeBatch()
        try await waitUntil("At least one window is published") { !app.recentWindows.isEmpty }
        XCTAssertTrue(app.batchActive)
        app.stop()
        try await waitUntil("Cancellation persists partial results") { !app.batchActive && !app.busy }
        let group = try XCTUnwrap(app.activeBatchGroup)
        defer { app.clearBatch(); try? BatchLogStore.delete(group.id) }
        XCTAssertEqual(group.status, .stopped)
        XCTAssertEqual(group.items[0].status, .stopped); XCTAssertEqual(group.items[1].status, .skipped)
        let record = try SoundSessionStore.load(XCTUnwrap(group.items[0].recordID))
        XCTAssertFalse(record.windows.isEmpty); XCTAssertNotNil(record.error)
        XCTAssertLessThan(record.windows.count, 500)
        XCTAssertNil(group.items[1].recordID)
    }

    func testLegacyRecordsDecodeAndInterruptedGroupsRecoverSavedResults() throws {
        let asset = SoundModelAsset(id: "yamnet", revision: "test", frameworkVersion: "test", source: "test",
            license: "test", modelFile: "test", labelsFile: "test", files: [])
        var record = SoundRecord(model: .yamnet, asset: asset, options: SoundOptions(), device: "test",
            actualInput: "file", actualInputUID: "file", material: MaterialInfo())
        let encoder = JSONEncoder()
        var oldJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(record)) as? [String: Any])
        oldJSON.removeValue(forKey: "batch")
        for version in [1, 2] {
            oldJSON["schemaVersion"] = version
            let restored = try JSONDecoder().decode(SoundRecord.self, from: JSONSerialization.data(withJSONObject: oldJSON))
            XCTAssertNil(restored.batch); XCTAssertEqual(restored.schemaVersion, version)
        }
        let itemID = UUID().uuidString
        var group = BatchLogGroup(name: "Recovery", model: .yamnet, options: SoundOptions(), items: [
            BatchLogItem(id: itemID, filename: "saved.wav", status: .analyzing, recordID: record.id),
            BatchLogItem(id: UUID().uuidString, filename: "unrun.wav")
        ])
        record.batch = BatchRecordLink(groupID: group.id, itemID: itemID, index: 0, total: 2)
        record.status = "完成"; record.endedAt = Date(); record.audioSeconds = 0.2
        try SoundSessionStore.save(record); try BatchLogStore.save(group)
        defer { try? BatchLogStore.delete(group.id) }
        try BatchLogStore.recoverInterrupted()
        group = try BatchLogStore.load(group.id)
        XCTAssertEqual(group.status, .interrupted)
        XCTAssertEqual(group.items[0].status, .completed); XCTAssertEqual(group.items[1].status, .skipped)
        XCTAssertEqual(group.items[0].recordID, record.id)
    }

    func testClearRemovesLogsButPreservesAudioAndIsSafeToRepeat() throws {
        let sessions = fixtures.appendingPathComponent("Sessions", isDirectory: true)
        let groups = sessions.appendingPathComponent("BatchGroups", isDirectory: true)
        try FileManager.default.createDirectory(at: groups, withIntermediateDirectories: true)
        try Data("damaged test record".utf8).write(to: sessions.appendingPathComponent("unreadable.json"))
        try Data("test group".utf8).write(to: groups.appendingPathComponent("group.json"))
        let preserved = try audio("preserved.wav")
        let before = try Data(contentsOf: preserved)
        try SoundSessionStore.clear(at: sessions)
        try SoundSessionStore.clear(at: sessions)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessions.path))
        XCTAssertEqual(try Data(contentsOf: preserved), before)
    }
}

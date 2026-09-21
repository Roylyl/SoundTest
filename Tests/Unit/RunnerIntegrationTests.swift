import XCTest
import Foundation
@testable import SoundTest

/// Real asynchronous runner tests with generated PCM, not microphone capture.
/// They verify file/live routing, tail accounting, finalization and persisted
/// records. They cannot measure capture hardware or real sound-event latency.
final class RunnerIntegrationTests: XCTestCase {
    private final class Capture {
        private let lock = NSLock()
        private var windows: [WindowResult] = []
        private var failures: [String] = []
        private var record: SoundRecord?
        func add(_ window: WindowResult) { lock.lock(); windows.append(window); lock.unlock() }
        func fail(_ message: String) { lock.lock(); failures.append(message); lock.unlock() }
        func finish(_ record: SoundRecord) { lock.lock(); self.record = record; lock.unlock() }
        func snapshot() -> ([WindowResult], [String], SoundRecord?) {
            lock.lock(); defer { lock.unlock() }; return (windows, failures, record)
        }
    }

    private func makeRunner() async throws -> (AnalysisRunner, SoundModelAsset, Double) {
        let runner = AnalysisRunner()
        let store = try SoundModelStore(root: XCTUnwrap(Bundle.main.resourceURL))
        let loaded: (SoundModelAsset, Double) = try await withCheckedThrowingContinuation { continuation in
            runner.load(model: .yamnet, store: store, threads: 2) { result in
                continuation.resume(with: result)
            }
        }
        return (runner, loaded.0, loaded.1)
    }

    private func record(asset: SoundModelAsset, loadMS: Double, live: Bool) throws -> SoundRecord {
        var options = SoundOptions()
        options.mode = live ? .continuous : .segment
        options.windowSeconds = 0.975
        options.stepSeconds = 0.975
        options = try options.validated(for: .yamnet)
        var value = SoundRecord(model: .yamnet, asset: asset, options: options,
                                device: "XCTest synthetic PCM (no microphone)",
                                actualInput: live ? "Generated PCM chunks (simulated live callbacks)" : "Generated PCM file-equivalent input",
                                actualInputUID: live ? "test-synthetic-live" : "test-synthetic-file",
                                material: MaterialInfo())
        value.material.inputMethod = live ? .environment : .file
        value.material.filename = live ? nil : "synthetic-silence-2s.wav"
        value.material.sampleID = "integration-generated-2s"
        value.material.manualLabel = "Synthetic silence; no target accuracy conclusion"
        value.material.source = "Generated Float32 PCM in XCTest; not microphone or bundled copyrighted fixture"
        value.loadMS = loadMS
        return value
    }

    private func begin(_ runner: AnalysisRunner, record: SoundRecord, live: Bool) async {
        await withCheckedContinuation { continuation in
            runner.begin(record, isLive: live) { continuation.resume() }
        }
    }

    private func assertWindowAccounting(_ record: SoundRecord,
                                         file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertNil(record.error, file: file, line: line)
        XCTAssertEqual(record.status, "完成", file: file, line: line)
        XCTAssertEqual(record.audioSeconds, 2, accuracy: 0.000001, file: file, line: line)
        XCTAssertEqual(record.windows.count, 3, file: file, line: line)
        let last = try XCTUnwrap(record.windows.last, file: file, line: line)
        XCTAssertEqual(last.start, 1.95, accuracy: 0.000001, file: file, line: line)
        XCTAssertEqual(last.end, 2, accuracy: 0.000001, file: file, line: line)
        XCTAssertEqual(last.modelInputSeconds, 0.975, accuracy: 0.000001, file: file, line: line)
        XCTAssertEqual(last.paddedSeconds, 0.925, accuracy: 0.000001, file: file, line: line)
        XCTAssertEqual(record.windows.map(\.index), [0, 1, 2], file: file, line: line)
        XCTAssertEqual(record.inferenceMS, record.windows.reduce(0) { $0 + $1.inferenceMS }, accuracy: 0.00001, file: file, line: line)
        for window in record.windows {
            XCTAssertEqual(window.scores.count, 521, file: file, line: line)
            XCTAssertTrue(window.scores.allSatisfy { $0.score.isFinite }, file: file, line: line)
            XCTAssertGreaterThanOrEqual(window.inferenceMS, 0, file: file, line: line)
            XCTAssertNil(window.trueEventLatencyMS, file: file, line: line)
        }
    }

    func testFileRunnerAnalyzesTwoSecondsAndPersistsPaddedTail() async throws {
        let (runner, asset, loadMS) = try await makeRunner()
        let state = Capture()
        let done = expectation(description: "File analysis finishes")
        runner.onWindow = { window, _ in state.add(window); return nil }
        runner.onFailure = { state.fail($0) }
        runner.onFinished = { result in state.finish(result); done.fulfill() }
        await begin(runner, record: try record(asset: asset, loadMS: loadMS, live: false), live: false)
        runner.analyzeFile([Float](repeating: 0, count: 32_000))
        await fulfillment(of: [done], timeout: 30)
        let (windows, failures, maybeRecord) = state.snapshot()
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
        let result = try XCTUnwrap(maybeRecord)
        try assertWindowAccounting(result)
        XCTAssertEqual(windows.count, 3)
        XCTAssertNil(result.stopWaitMS)
        for window in result.windows {
            XCTAssertNil(window.windowCollectionSeconds)
            XCTAssertNil(window.queueDelayMS)
            XCTAssertNil(window.promptAfterWindowMS)
            XCTAssertNil(window.presentedAt)
        }
        try SoundSessionStore.save(result)
        defer { try? SoundSessionStore.delete(result) }
        let stored = try JSONDecoder().decode(SoundRecord.self, from: Data(contentsOf: SoundSessionStore.url(result.id)))
        XCTAssertEqual(stored.id, result.id)
        XCTAssertEqual(stored.windows.count, result.windows.count)
        XCTAssertEqual(stored.windows.last?.paddedSeconds, result.windows.last?.paddedSeconds)
        XCTAssertEqual(stored.windows.first?.scores.map(\.score), result.windows.first?.scores.map(\.score))
        XCTAssertEqual(stored.material.sampleID, "integration-generated-2s")
        try writeEvidence(result, filename: "runner-file-integration-verification.json")
    }

    func testSimulatedLivePCMRoutingFinalizesOnceAndKeepsRecordingInMemory() async throws {
        let (runner, asset, loadMS) = try await makeRunner()
        let state = Capture()
        let done = expectation(description: "Simulated live analysis finishes")
        done.assertForOverFulfill = true
        runner.onWindow = { window, _ in state.add(window); return Date() }
        runner.onFailure = { state.fail($0) }
        runner.onFinished = { result in state.finish(result); done.fulfill() }
        await begin(runner, record: try record(asset: asset, loadMS: loadMS, live: true), live: true)
        // No wall-clock pacing: this verifies queue routing, not real-time capture latency.
        for _ in 0..<10 { runner.push([Float](repeating: 0, count: 3_200), rate: 16_000) }
        runner.finish(stopTime: ProcessInfo.processInfo.systemUptime)
        // A duplicate stop should be harmless once the queued record has finalized.
        runner.finish()
        await fulfillment(of: [done], timeout: 30)
        await withCheckedContinuation { continuation in runner.queue.async { continuation.resume() } }
        let (windows, failures, maybeRecord) = state.snapshot()
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
        let result = try XCTUnwrap(maybeRecord)
        try assertWindowAccounting(result)
        XCTAssertEqual(windows.count, 3)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(result.stopWaitMS), 0)
        for window in result.windows {
            XCTAssertEqual(try XCTUnwrap(window.windowCollectionSeconds), window.end - window.start, accuracy: 0.000001)
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(window.queueDelayMS), 0)
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(window.promptAfterWindowMS), 0)
            XCTAssertNotNil(window.presentedAt)
        }
        let retained: [Float] = await withCheckedContinuation { continuation in
            runner.clip { continuation.resume(returning: $0) }
        }
        XCTAssertEqual(retained.count, 32_000)
        XCTAssertNil(result.material.savedAudioName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: SoundSessionStore.url(result.id).path),
                       "The runner returns a record; persistence must be explicitly performed by its owner.")
        try writeEvidence(result, filename: "runner-live-integration-verification.json")
    }

    private func writeEvidence(_ result: SoundRecord, filename: String) throws {
        let folder = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let output = folder.appendingPathComponent(filename)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(result).write(to: output, options: .atomic)
        print("RUNNER_INTEGRATION_ARTIFACT \(output.path)")
    }
}

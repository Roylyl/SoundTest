import XCTest
import Foundation
import UIKit
@testable import SoundTest

/// Hosted integration checks: these open the model bytes shipped in the host App
/// and invoke its actual Swift/C/C++ wrappers. Scores and timing here are smoke
/// evidence, not environmental-sound accuracy or iPhone performance measurements.
final class ModelIntegrationTests: XCTestCase {
    private static let artifactLock = NSLock()
    private static var checks: [[String: Any]] = []

    private func store() throws -> SoundModelStore {
        let root = try XCTUnwrap(Bundle.main.resourceURL)
        XCTAssertNotNil(Bundle.main.bundleIdentifier)
        return try SoundModelStore(root: root)
    }

    private func makeEngine(_ id: SoundModelID, store: SoundModelStore,
                            asset: SoundModelAsset) throws -> TaggingEngine {
        let folder = store.folder(id)
        let modelURL = folder.appendingPathComponent(asset.modelFile)
        let labelsURL = folder.appendingPathComponent(asset.labelsFile)
        if id == .cpMobile { return try CPMobileTagger(modelURL: modelURL, labelsURL: labelsURL, threads: 2) }
        if id == .efficientAT {
            return try EfficientATTagger(modelURL: modelURL, labelsURL: labelsURL,
                melURL: folder.appendingPathComponent("mel-bank.f32"),
                hannURL: folder.appendingPathComponent("hann-window.f32"), threads: 2)
        }
        if id == .yamnet {
            return try YAMNetTagger(modelURL: modelURL, labelsURL: labelsURL, threads: 2)
        }
        return try SherpaTagger(modelID: id, modelURL: modelURL, labelsURL: labelsURL, threads: 2)
    }

    private func checkScores(_ scores: [RawScore], model: SoundModelID,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(scores.count, model.expectedCount, file: file, line: line)
        XCTAssertEqual(Set(scores.map(\.index)), Set(0..<model.expectedCount), file: file, line: line)
        XCTAssertTrue(scores.allSatisfy { !$0.label.isEmpty }, file: file, line: line)
        XCTAssertTrue(scores.allSatisfy { $0.score.isFinite && (0...1).contains($0.score) }, file: file, line: line)
        for label in (model.task == .scenes ? Set(SceneAnalysis.labels) : Set(TargetCategory.all.flatMap(\.labels))) {
            XCTAssertEqual(scores.filter { $0.label == label }.count, 1,
                           "Each configured target label must have a raw score even outside Top-5: \(label)", file: file, line: line)
        }
    }

    func testPackagedModelsExecuteAndReleaseAcrossTwoPasses() throws {
        let store = try store()
        XCTAssertEqual(Set(store.assets.map(\.id)), Set(SoundModelID.allCases.map(\.rawValue)))
        var previousLabels: [SoundModelID: [String]] = [:]
        for pass in 1...2 {
            // Reverse the second pass so engine-family transitions and reloads are covered.
            let ids = pass == 1 ? SoundModelID.allCases : Array(SoundModelID.allCases.reversed())
            for id in ids {
                weak var releasedEngine: AnyObject?
                try autoreleasepool {
                    XCTAssertTrue(store.available(id), "Packaged model missing or wrong size: \(id.rawValue)")
                    let asset = try store.validate(id)
                    let loadStart = ProcessInfo.processInfo.systemUptime
                    let engine = try makeEngine(id, store: store, asset: asset)
                    releasedEngine = engine
                    let loadMS = (ProcessInfo.processInfo.systemUptime - loadStart) * 1_000
                    let count = Int((id.defaultWindow * Double(id.sampleRate)).rounded())
                    let samples = [Float](repeating: 0, count: count)
                    let start = ProcessInfo.processInfo.systemUptime
                    let scores = try engine.classify(samples: samples, sampleRate: id.sampleRate)
                    let inferenceMS = (ProcessInfo.processInfo.systemUptime - start) * 1_000
                    checkScores(scores, model: id)
                    let ordered = scores.sorted { $0.index < $1.index }
                    if let labels = previousLabels[id] {
                        XCTAssertEqual(ordered.map(\.label), labels, "Labels changed after unloading and reloading \(id.rawValue)")
                    } else { previousLabels[id] = ordered.map(\.label) }
                    try appendArtifact([
                        "check": "real_packaged_model_inference", "status": "completed",
                        "model": id.rawValue, "pass": pass,
                        "revision": asset.revision, "frameworkVersion": asset.frameworkVersion,
                        "input": "synthetic_silence", "sampleRate": id.sampleRate, "sampleCount": count,
                        "loadMS": loadMS, "inferenceCallMS": inferenceMS,
                        "scoreCount": scores.count,
                        "top5": scores.sorted { $0.score > $1.score }.prefix(5).map(Self.scoreJSON),
                        "rawScores": ordered.map(Self.scoreJSON)
                    ])
                }
                XCTAssertNil(releasedEngine, "The previous engine must be released before switching to another model.")
            }
        }
    }

    func testYAMNetRejectsMalformedInputsAndAcceptsExplicitPadding() throws {
        let store = try store()
        let asset = try store.validate(.yamnet)
        let engine = try makeEngine(.yamnet, store: store, asset: asset)
        let malformed: [(String, [Float], Int)] = [
            ("empty", [], 16_000),
            ("one_sample_short", [Float](repeating: 0, count: 15_599), 16_000),
            ("wrong_sample_rate", [Float](repeating: 0, count: 15_600), 44_100),
            ("non_finite", [Float.nan] + [Float](repeating: 0, count: 15_599), 16_000)
        ]
        var rejected: [String] = []
        for (name, samples, rate) in malformed {
            XCTAssertThrowsError(try engine.classify(samples: samples, sampleRate: rate), name) { _ in
                rejected.append(name)
            }
        }
        // This tests only the wrapper contract. Timeline padding accounting is
        // tested separately against WindowPlanner/AnalysisRunner.
        let actualCount = 1_600
        var padded = [Float](repeating: 0, count: actualCount)
        padded.append(contentsOf: repeatElement(0, count: 15_600 - actualCount))
        let scores = try engine.classify(samples: padded, sampleRate: 16_000)
        checkScores(scores, model: .yamnet)
        XCTAssertEqual(rejected.count, malformed.count)
        try appendArtifact([
            "check": "yamnet_shape_rate_and_finite_validation", "status": "completed",
            "rejectedCases": rejected, "actualAudioSeconds": 0.1,
            "explicitPaddedSeconds": Double(15_600 - actualCount) / 16_000,
            "modelInputSeconds": 0.975, "paddedOutputScoreCount": scores.count
        ])
    }

    func testManifestRejectsSameLengthTamperingWithoutChangingBundle() throws {
        let original = try store()
        let asset = try original.validate(.yamnet)
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent("SoundTest-model-integrity-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: temporary.appendingPathComponent("ModelLibrary"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temporary) }
        try fm.copyItem(at: original.root.appendingPathComponent("ModelsManifest.json"),
                        to: temporary.appendingPathComponent("ModelsManifest.json"))
        try fm.copyItem(at: original.folder(.yamnet), to: temporary.appendingPathComponent("ModelLibrary/yamnet"))
        let copiedStore = try SoundModelStore(root: temporary)
        _ = try copiedStore.validate(.yamnet)
        let copiedLabels = copiedStore.folder(.yamnet).appendingPathComponent(asset.labelsFile)
        let before = try Data(contentsOf: copiedLabels)
        var changed = before
        XCTAssertFalse(changed.isEmpty)
        changed[changed.startIndex] ^= 0x01
        try changed.write(to: copiedLabels, options: .atomic)
        XCTAssertEqual(before.count, changed.count)
        XCTAssertTrue(copiedStore.available(.yamnet), "The shallow availability check should still see the same file size.")
        var refused = false
        XCTAssertThrowsError(try copiedStore.validate(.yamnet)) { _ in refused = true }
        XCTAssertTrue(refused, "A same-length resource edit must fail SHA-256 validation before loading.")
        // Ensure the host App resources were never modified.
        _ = try original.validate(.yamnet)
        try appendArtifact([
            "check": "sha256_same_length_tamper", "status": "completed",
            "model": "yamnet", "file": asset.labelsFile,
            "bytesBefore": before.count, "bytesAfter": changed.count,
            "refused": refused, "hostBundleRevalidated": true
        ])
    }

    private static func scoreJSON(_ value: RawScore) -> [String: Any] {
        ["index": value.index, "label": value.label, "score": value.score]
    }

    private func appendArtifact(_ check: [String: Any]) throws {
        Self.artifactLock.lock()
        defer { Self.artifactLock.unlock() }
        Self.checks.append(check)
        #if targetEnvironment(simulator)
        let environment = "iOS Simulator; not iPhone accuracy/performance validation"
        #else
        let environment = "iOS device; synthetic integration checks only"
        #endif
        let report: [String: Any] = [
            "schemaVersion": 1,
            "generatedAt": ISO8601DateFormatter().string(from: Date()),
            "environment": environment,
            "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
            "hostBundleIdentifier": Bundle.main.bundleIdentifier ?? "unknown",
            "hostAppVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "metricDefinition": "inferenceCallMS measures actual classify invocation only; synthetic silence is not target accuracy, and simulator time is not an iPhone benchmark",
            "checks": Self.checks
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let destination = documents.appendingPathComponent("model-integration-verification.json")
        try data.write(to: destination, options: .atomic)
        print("MODEL_INTEGRATION_ARTIFACT \(destination.path)")
    }
}

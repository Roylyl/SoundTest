import XCTest
import Foundation
@testable import SoundTest

/// One fixed public clip per category checks the actual local audio→window→model pipeline.
/// Expected labels are evaluation metadata only. No classification threshold is a pass criterion.
final class EnvironmentSampleTests: XCTestCase {
    private struct Manifest: Decodable {
        let revision: String
        let clips: [Clip]
    }
    private struct Clip: Decodable {
        let testCase: String
        let filename: String
        let targetID: String
        let expectedLabel: String
        let bytes: Int
        let sha256: String
    }
    private struct Sample {
        let testCase: String
        let filename: String?
        let targetID: String?
        let expectedLabel: String?
        let samples: [Float]
        let originalSampleRate: Double
        let originalChannels: Int
    }

    func testFourTargetClipsAndSilenceAcrossPackagedModels() throws {
        let metadataURL = try fixtureURL("EnvironmentFixtures.json")
        let metadataData = try Data(contentsOf: metadataURL)
        let manifest = try JSONDecoder().decode(Manifest.self, from: metadataData)
        let metadata = try JSONSerialization.jsonObject(with: metadataData)
        XCTAssertEqual(manifest.revision, "33c8ce9eb2cf0b1c2f8bcf322eb349b6be34dbb6")
        XCTAssertEqual(manifest.clips.count, 4)

        var samples: [Sample] = []
        for clip in manifest.clips {
            let url = try fixtureURL(clip.filename)
            XCTAssertEqual(try Data(contentsOf: url).count, clip.bytes)
            XCTAssertEqual(try SoundModelStore.sha256(url), clip.sha256)
            let decoded = try AudioFileIO.load(url: url)
            XCTAssertEqual(decoded.originalSampleRate, 44_100)
            XCTAssertEqual(decoded.channels, 1)
            XCTAssertEqual(decoded.samples.count, 80_000)
            samples.append(Sample(testCase: clip.testCase, filename: clip.filename,
                                  targetID: clip.targetID, expectedLabel: clip.expectedLabel,
                                  samples: decoded.samples, originalSampleRate: decoded.originalSampleRate,
                                  originalChannels: decoded.channels))
        }
        // Digital silence is a separate functional negative control, not a quiet-room field recording.
        samples.append(Sample(testCase: "S06", filename: nil, targetID: nil, expectedLabel: nil,
                              samples: [Float](repeating: 0, count: 80_000),
                              originalSampleRate: 16_000, originalChannels: 1))
        let store = try SoundModelStore(root: XCTUnwrap(Bundle.main.resourceURL))
        var resultRows: [[String: Any]] = []
        for model in SoundModelID.allCases {
            try autoreleasepool {
                let asset = try store.validate(model)
                let folder = store.folder(model)
                let modelURL = folder.appendingPathComponent(asset.modelFile)
                let labelsURL = folder.appendingPathComponent(asset.labelsFile)
                let engine: TaggingEngine = model == .yamnet
                    ? try YAMNetTagger(modelURL: modelURL, labelsURL: labelsURL, threads: 2)
                    : try SherpaTagger(modelID: model, modelURL: modelURL, labelsURL: labelsURL, threads: 2)
                var options = SoundOptions()
                options.mode = .continuous
                options.windowSeconds = model.defaultWindow; options.stepSeconds = model.defaultStep
                _ = try options.validated(for: model)
                for sample in samples {
                    var planner = WindowPlanner(options: options)
                    var windows: [WindowResult] = []
                    var events: [EventEstimate] = []
                    while let range = planner.next(total: sample.samples.count, finishing: true) {
                        // Only PCM values and a sample rate cross the model API boundary.
                        var input = Array(sample.samples[range])
                        let padding = planner.windowSamples - input.count
                        input.append(contentsOf: repeatElement(0, count: padding))
                        let start = ProcessInfo.processInfo.systemUptime
                        let scores = try engine.classify(samples: input, sampleRate: 16_000)
                        let inferenceMS = (ProcessInfo.processInfo.systemUptime - start) * 1_000
                        XCTAssertEqual(scores.count, model.expectedCount)
                        XCTAssertEqual(Set(scores.map(\.index)), Set(0..<model.expectedCount))
                        XCTAssertTrue(scores.allSatisfy { $0.score.isFinite && (0...1).contains($0.score) })
                        for target in TargetCategory.all where target.primary {
                            XCTAssertEqual(scores.filter { target.labels.contains($0.label) }.count, 1,
                                           "Primary class must retain its raw score even outside Top-5: \(target.id)")
                        }
                        let window = WindowResult(index: windows.count, start: Double(range.lowerBound) / 16_000,
                            end: Double(range.upperBound) / 16_000, modelInputSeconds: Double(input.count) / 16_000,
                            paddedSeconds: Double(padding) / 16_000, scores: scores,
                            targets: EventAnalysis.targets(scores: scores, options: options), inferenceMS: inferenceMS,
                            processingFinishedAt: Date(), windowCollectionSeconds: nil,
                            queueDelayMS: nil, promptAfterWindowMS: nil)
                        windows.append(window)
                        EventAnalysis.append(window, to: &events, options: options)
                    }
                    XCTAssertFalse(windows.isEmpty)
                    XCTAssertEqual(try XCTUnwrap(windows.last).end, 5.0, accuracy: 0.000001)
                    let meanScores = EventAnalysis.average(windows)
                    let primary: [[String: Any]] = TargetCategory.all.filter(\.primary).map { category in
                        let values = windows.flatMap(\.scores).filter { category.labels.contains($0.label) }
                        let peak = values.max { $0.score < $1.score }
                        return ["targetID": category.id,
                                "originalLabel": peak?.label as Any? ?? NSNull(),
                                "peakWindowScore": peak?.score as Any? ?? NSNull(),
                                "threshold": options.thresholds[category.id] ?? 0.3,
                                "promptedInAnyWindow": events.contains { $0.categoryID == category.id }]
                    }
                    let row: [String: Any] = [
                        "status": "functional_smoke_completed",
                        "model": model.rawValue, "modelRevision": asset.revision,
                        "frameworkVersion": asset.frameworkVersion,
                        "testCase": sample.testCase,
                        "inputMethod": "direct_file_decode_or_synthetic_silence",
                        "filename": sample.filename as Any? ?? NSNull(),
                        "expectedTargetID": sample.targetID as Any? ?? NSNull(),
                        "expectedLabelForComparisonOnly": sample.expectedLabel as Any? ?? NSNull(),
                        "originalSampleRate": sample.originalSampleRate,
                        "originalChannels": sample.originalChannels, "modelSampleRate": 16_000,
                        "audioSeconds": Double(sample.samples.count) / 16_000,
                        "windowSeconds": options.windowSeconds, "stepSeconds": options.stepSeconds,
                        "mergeGapSeconds": options.mergeGapSeconds, "mappingVersion": ChineseLabels.version,
                        "inferenceCallMS": windows.reduce(0) { $0 + $1.inferenceMS },
                        "windowCollectionSeconds": NSNull(), "trueEventLatencyMS": NSNull(),
                        "primaryScores": primary,
                        "meanWindowTop5": meanScores.sorted { $0.score > $1.score }.prefix(5).map(Self.scoreJSON),
                        "windows": try json(windows), "eventEstimates": try json(events)
                    ]
                    resultRows.append(row)
                    print("ENVIRONMENT_SAMPLE \(model.rawValue) \(sample.testCase) " + primary.map {
                        "\($0["targetID"]!)=\($0["peakWindowScore"]!)"
                    }.joined(separator: " "))
                    try writeArtifact(rows: resultRows, metadata: metadata)
                }
            }
        }
        XCTAssertEqual(resultRows.count, 20)
    }

    private func fixtureURL(_ filename: String) throws -> URL {
        let bundle = Bundle(for: Self.self)
        let file = filename as NSString
        // Xcode synchronized resource groups can retain the Fixtures folder or flatten individual files.
        return try XCTUnwrap(bundle.url(forResource: file.deletingPathExtension, withExtension: file.pathExtension, subdirectory: "Fixtures")
            ?? bundle.url(forResource: file.deletingPathExtension, withExtension: file.pathExtension),
            "Missing test-only fixture \(filename); include Tests/Unit/Fixtures in the test target resources.")
    }

    private static func scoreJSON(_ score: RawScore) -> [String: Any] {
        ["index": score.index, "label": score.label, "score": score.score]
    }

    private func json<T: Encodable>(_ value: T) throws -> Any {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return try JSONSerialization.jsonObject(with: encoder.encode(value))
    }

    private func writeArtifact(rows: [[String: Any]], metadata: Any) throws {
        #if targetEnvironment(simulator)
        let environment = "iOS Simulator; no iPhone microphone, accuracy or performance claim"
        #else
        let environment = "iOS device; file-only functional smoke, no microphone accuracy claim"
        #endif
        let report: [String: Any] = ["schemaVersion": 1,
            "generatedAt": ISO8601DateFormatter().string(from: Date()), "environment": environment,
            "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
            "fixtureMetadata": metadata,
            "scope": "One fixed public sample per S01-S04 category and one digital-silence S06 control; checks decoding and real engine output validity, not accuracy. Target labels do not condition prediction. Scores are not accuracy. Silence is not a real quiet environment.",
            "metricDefinition": "inferenceCallMS sums real classify calls only. No recording, window collection wait or physical event latency is measured. Default model windows differ; peak-window scores summarize presence, not comparable calibrated probabilities.",
            "results": rows]
        let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                    appropriateFor: nil, create: true)
        let destination = documents.appendingPathComponent("environment-samples-verification.json")
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: destination, options: .atomic)
        print("ENVIRONMENT_SAMPLE_ARTIFACT \(destination.path)")
    }
}

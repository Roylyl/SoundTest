import XCTest
@testable import SoundTest

final class AnalysisTests: XCTestCase {
    private func score(_ label: String, _ value: Double, index: Int = 0) -> RawScore {
        RawScore(index: index, label: label, score: value)
    }

    private func window(index: Int, start: Double, end: Double,
                        scores: [RawScore], options: SoundOptions) -> WindowResult {
        WindowResult(index: index, start: start, end: end,
            modelInputSeconds: options.windowSeconds,
            paddedSeconds: max(0, options.windowSeconds - (end - start)),
            scores: scores, targets: EventAnalysis.targets(scores: scores, options: options),
            inferenceMS: 7, processingFinishedAt: Date(timeIntervalSince1970: 0),
            windowCollectionSeconds: nil, queueDelayMS: nil, promptAfterWindowMS: nil)
    }

    private func allRanges(total: Int, options: SoundOptions) -> [Range<Int>] {
        var planner = WindowPlanner(options: options)
        var ranges: [Range<Int>] = []
        while let range = planner.next(total: total, finishing: true) { ranges.append(range) }
        return ranges
    }

    func testIndependentTargetsCanPromptSimultaneously() {
        let options = SoundOptions()
        let values = EventAnalysis.targets(scores: [score("Bark", 0.8, index: 75),
            score("Cough", 0.7, index: 42), score("Knock", 0.1, index: 366)], options: options)
        XCTAssertEqual(Set(values.filter(\.prompted).map(\.id)), Set(["bark", "cough"]))
        XCTAssertEqual(values.first { $0.id == "bark" }?.originalLabel, "Bark")
        var events: [EventEstimate] = []
        EventAnalysis.append(window(index: 0, start: 0, end: 10,
            scores: [score("Bark", 0.8), score("Cough", 0.7, index: 1)], options: options),
            to: &events, options: options)
        XCTAssertEqual(Set(events.map(\.categoryID)), Set(["bark", "cough"]))
    }

    func testMissingTargetRemainsNilAndParentLabelDoesNotSubstitute() {
        let values = EventAnalysis.targets(scores: [score("Dog", 0.99), score("Speech", 0.9, index: 1)],
                                           options: SoundOptions())
        let bark = values.first { $0.id == "bark" }
        XCTAssertNil(bark?.score)
        XCTAssertNil(bark?.originalLabel)
        XCTAssertFalse(bark?.prompted ?? true)
        XCTAssertFalse(values.contains(where: \.prompted))
    }

    func testBelowThresholdDoesNotPromptAndExtensionSettingIsRespected() {
        var options = SoundOptions()
        options.thresholds["bark"] = 0.8
        let raw = [score("Bark", 0.799), score("Doorbell", 0.95, index: 1)]
        XCTAssertFalse(EventAnalysis.targets(scores: raw, options: options).contains(where: \.prompted))
        options.includeExtensions = true
        XCTAssertEqual(EventAnalysis.targets(scores: raw, options: options).filter(\.prompted).map(\.id), ["doorbell"])
    }

    func testExactFullWindowDoesNotCreateDuplicateTail() {
        let options = SoundOptions() // 10 second window, 2 second step
        XCTAssertEqual(allRanges(total: 160_000, options: options), [0..<160_000])
        XCTAssertEqual(allRanges(total: 192_000, options: options), [0..<160_000, 32_000..<192_000])
        XCTAssertEqual(allRanges(total: 0, options: options), [])
    }

    func testStreamingPlannerOnlyAddsOneFinalPartialWindow() {
        var planner = WindowPlanner(options: SoundOptions())
        XCTAssertNil(planner.next(total: 80_000, finishing: false))
        XCTAssertEqual(planner.next(total: 160_000, finishing: false), 0..<160_000)
        XCTAssertNil(planner.next(total: 160_000, finishing: false))
        XCTAssertEqual(planner.next(total: 208_000, finishing: false), 32_000..<192_000)
        XCTAssertNil(planner.next(total: 208_000, finishing: false))
        XCTAssertEqual(planner.next(total: 208_000, finishing: true), 64_000..<208_000)
        XCTAssertNil(planner.next(total: 208_000, finishing: true))
        XCTAssertEqual(planner.coveredEnd, 208_000)
    }

    func testShortInputPreservesRealEvidenceBoundsDespitePadding() {
        let options = SoundOptions()
        XCTAssertEqual(allRanges(total: 8_000, options: options), [0..<8_000])
        let short = window(index: 0, start: 0, end: 0.5, scores: [score("Bark", 0.8)], options: options)
        XCTAssertEqual(short.modelInputSeconds, 10)
        XCTAssertEqual(short.paddedSeconds, 9.5)
        var events: [EventEstimate] = []
        EventAnalysis.append(short, to: &events, options: options)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].evidenceStart, 0)
        XCTAssertEqual(events[0].evidenceEnd, 0.5)
        XCTAssertGreaterThanOrEqual(events[0].estimatedStart, 0)
        XCTAssertLessThanOrEqual(events[0].estimatedEnd, 0.5)
        XCTAssertNil(short.trueEventLatencyMS)
    }

    func testEvidenceRangeAndEstimatedRangeAreDistinct() {
        let options = SoundOptions()
        var events: [EventEstimate] = []
        EventAnalysis.append(window(index: 0, start: 0, end: 10,
            scores: [score("Bark", 0.7)], options: options), to: &events, options: options)
        XCTAssertEqual(events[0].evidenceStart, 0)
        XCTAssertEqual(events[0].evidenceEnd, 10)
        XCTAssertEqual(events[0].estimatedStart, 4)
        XCTAssertEqual(events[0].estimatedEnd, 6)
    }

    func testAdjacentWindowsMergeWithoutMergingDifferentClasses() {
        let options = SoundOptions()
        var events: [EventEstimate] = []
        EventAnalysis.append(window(index: 0, start: 0, end: 10,
            scores: [score("Bark", 0.7)], options: options), to: &events, options: options)
        EventAnalysis.append(window(index: 1, start: 2, end: 12,
            scores: [score("Bark", 0.9), score("Cough", 0.8, index: 1)], options: options),
            to: &events, options: options)
        XCTAssertEqual(events.count, 2)
        let bark = events.first { $0.categoryID == "bark" }!
        XCTAssertEqual(bark.windowIndices, [0, 1])
        XCTAssertEqual(bark.peakScore, 0.9)
        XCTAssertEqual(bark.evidenceEnd, 12)
        XCTAssertEqual(bark.estimatedEnd, 8)
    }

    func testConfiguredGapControlsEventMerge() {
        func count(gap: Double) -> Int {
            var options = SoundOptions(); options.mergeGapSeconds = gap
            var events: [EventEstimate] = []
            EventAnalysis.append(window(index: 0, start: 0, end: 10,
                scores: [score("Bark", 0.7)], options: options), to: &events, options: options)
            EventAnalysis.append(window(index: 1, start: 4, end: 14,
                scores: [score("Bark", 0.8)], options: options), to: &events, options: options)
            return events.count
        }
        XCTAssertEqual(count(gap: 1.9), 2)
        XCTAssertEqual(count(gap: 2), 1)
    }

    func testAverageOmitsMissingClassInsteadOfInventingZero() {
        let options = SoundOptions()
        let first = window(index: 0, start: 0, end: 10,
                           scores: [score("Bark", 0.8), score("Cough", 0.5, index: 1)], options: options)
        let second = window(index: 1, start: 2, end: 12,
                            scores: [score("Bark", 0.4)], options: options)
        let average = EventAnalysis.average([first, second])
        XCTAssertEqual(average.count, 1)
        XCTAssertEqual(average[0].label, "Bark")
        XCTAssertEqual(average[0].score, 0.6, accuracy: 0.000001)
    }

    func testFixedYAMNetWindowAndVariableSherpaWindowValidation() {
        var options = SoundOptions()
        XCTAssertNoThrow(try options.validated(for: .zipformer))
        XCTAssertThrowsError(try options.validated(for: .yamnet))
        options.windowSeconds = 0.975; options.stepSeconds = 0.48
        XCTAssertNoThrow(try options.validated(for: .yamnet))
        XCTAssertThrowsError(try options.validated(for: .cedTiny))
        options.windowSeconds = 1
        XCTAssertNoThrow(try options.validated(for: .cedTiny))
        XCTAssertThrowsError(try options.validated(for: .yamnet))
        options.windowSeconds = 30; options.stepSeconds = 30
        XCTAssertNoThrow(try options.validated(for: .cedMini))
        options.stepSeconds = 31
        XCTAssertThrowsError(try options.validated(for: .cedMini))
    }

    func testNonfiniteThresholdAndMissingThresholdAreRejected() {
        var options = SoundOptions()
        options.thresholds["bark"] = .nan
        XCTAssertThrowsError(try options.validated(for: .zipformer))
        options.thresholds.removeValue(forKey: "bark")
        XCTAssertThrowsError(try options.validated(for: .zipformer))
    }

    // TaggingEngine accepts only PCM samples and sample rate. Filenames, sample IDs,
    // test numbers and manual labels live in MaterialInfo; they have no predictor input slot.
    // This compile-time adapter keeps that contract explicit without pretending to test model accuracy.
    func testPredictorContractAcceptsAudioWithoutMaterialMetadata() throws {
        final class ContractEngine: TaggingEngine {
            var received: [Float] = []
            var rate = 0
            func classify(samples: [Float], sampleRate: Int) throws -> [RawScore] {
                received = samples; rate = sampleRate; return []
            }
        }
        let engine = ContractEngine()
        let classify: ([Float], Int) throws -> [RawScore] = engine.classify
        _ = try classify([0.2, -0.1], 16_000)
        XCTAssertEqual(engine.received, [0.2, -0.1])
        XCTAssertEqual(engine.rate, 16_000)
    }
}

import XCTest
import Foundation
@testable import SoundTest

/// Golden 10-second waveform from the upstream frontend, with an independent
/// PyTorch reference Mel matrix. This catches preprocessing drift that an ONNX
/// network-only comparison would miss.
final class EfficientATIntegrationTests: XCTestCase {
    private func fixture(_ name: String) throws -> URL {
        let bundle = Bundle(for: Self.self)
        let file = name as NSString
        return try XCTUnwrap(
            bundle.url(forResource: file.deletingPathExtension, withExtension: file.pathExtension,
                       subdirectory: "Fixtures/EfficientATGolden")
            ?? bundle.url(forResource: file.deletingPathExtension, withExtension: file.pathExtension,
                          subdirectory: "EfficientATGolden")
            ?? bundle.url(forResource: file.deletingPathExtension, withExtension: file.pathExtension),
            "Missing EfficientAT golden fixture \(name)"
        )
    }

    func testActualIOSFrontendMatchesPyTorchGoldenMel() throws {
        let store = try SoundModelStore(), asset = try store.validate(.efficientAT)
        let folder = store.folder(.efficientAT)
        let engine = try EfficientATTagger(modelURL: folder.appendingPathComponent(asset.modelFile),
            labelsURL: folder.appendingPathComponent(asset.labelsFile),
            melURL: folder.appendingPathComponent("mel-bank.f32"),
            hannURL: folder.appendingPathComponent("hann-window.f32"), threads: 2)
        let audio = try AudioFileIO.load(url: fixture("golden_audio_10s_32k_mono_pcm16.wav"), sampleRate: 32_000)
        XCTAssertEqual(audio.samples.count, 320_000)
        let mel = try engine.extractFeatures(samples: audio.samples, sampleRate: 32_000)
        let data = try Data(contentsOf: fixture("mel_10s_128x1000_f32le.bin"))
        XCTAssertEqual(data.count, mel.count * MemoryLayout<Float>.size)
        let reference = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        XCTAssertEqual(reference.count, 128_000)
        let differences = zip(mel, reference).map { abs($0 - $1) }
        let maxError = try XCTUnwrap(differences.max())
        let meanError = differences.reduce(0, +) / Float(differences.count)
        XCTAssertLessThan(maxError, 1e-4, "Mobile frontend differs from upstream PyTorch")
        XCTAssertLessThan(meanError, 1e-5)

        let scores = try engine.classify(samples: audio.samples, sampleRate: 32_000)
        XCTAssertEqual(scores.count, 527)
        XCTAssertEqual(Set(scores.map(\.index)), Set(0..<527))
        XCTAssertTrue(scores.allSatisfy { $0.score.isFinite && (0...1).contains($0.score) })
        let expectedData = try Data(contentsOf: fixture("mn10_scores_10s_527_pytorch_frontend_f32le.bin"))
        let expectedScores = expectedData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        XCTAssertEqual(expectedScores.count, 527)
        let maxScoreError = try XCTUnwrap(zip(scores, expectedScores)
            .map { abs($0.0.score - Double($0.1)) }.max())
        XCTAssertLessThan(maxScoreError, 1e-4, "Complete iOS audio-to-score path differs from reference")
        print("EFFICIENTAT_GOLDEN maxMelError=\(maxError) meanMelError=\(meanError) maxScoreError=\(maxScoreError) top5=\(scores.sorted { $0.score > $1.score }.prefix(5).map { "\($0.label):\($0.score)" })")
    }
}

import Foundation
import SherpaTagging

/// Entire published frontend (STFT, HTK mel, log) lives inside the verified ONNX graph.
final class CPMobileTagger: TaggingEngine {
    private let handle: UnsafeMutableRawPointer
    private let labels: [String]
    init(modelURL: URL, labelsURL: URL, threads: Int = 2) throws {
        labels = try String(contentsOf: labelsURL, encoding: .utf8).split(whereSeparator: \.isNewline).map(String.init)
        guard labels == SceneAnalysis.labels else { throw SoundError.message("CP-Mobile 类别顺序校验失败。") }
        var error = [CChar](repeating: 0, count: 2048)
        guard let value = SoundASCLoad(modelURL.path, Int32(threads), &error, error.count) else {
            throw SoundError.message(String(cString: error))
        }
        handle = value
    }
    deinit { SoundASCRelease(handle) }
    func classify(samples: [Float], sampleRate: Int) throws -> [RawScore] {
        guard sampleRate == 32000, samples.count == 32000, samples.allSatisfy(\.isFinite) else {
            throw SoundError.message("CP-Mobile 需要1秒32 kHz单声道音频。")
        }
        var logits = [Float](repeating: 0, count: 10), error = [CChar](repeating: 0, count: 2048)
        guard SoundASCRun(handle, samples, samples.count, &logits, &error, error.count) == 1,
              logits.allSatisfy(\.isFinite) else { throw SoundError.message("ASC 推理失败：" + String(cString: error)) }
        let peak = logits.max()!, values = logits.map { exp(Double($0 - peak)) }, sum = values.reduce(0,+)
        return values.enumerated().map { RawScore(index: $0.offset, label: labels[$0.offset], score: $0.element / sum) }
    }
}

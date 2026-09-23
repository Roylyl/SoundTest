import Foundation
import SherpaTagging

/// Offline EfficientAT mn10_as: the app supplies a padded 10-second, 32 kHz window.
/// The native bridge reproduces the upstream log-Mel frontend and runs the verified
/// ONNX conversion. Neither filenames nor human labels enter this model.
final class EfficientATTagger: TaggingEngine {
    private let handle: UnsafeMutableRawPointer
    private let labels: [Int: String]

    init(modelURL: URL, labelsURL: URL, melURL: URL, hannURL: URL, threads: Int) throws {
        labels = try SherpaTagger.readLabels(labelsURL)
        guard labels.count == 527, Set(labels.keys) == Set(0..<527) else {
            throw SoundError.message("EfficientAT 类别表必须包含 527 个不重复标签。")
        }
        var error = [CChar](repeating: 0, count: 2048)
        guard let loaded = SoundEfficientATLoad(modelURL.path, melURL.path, hannURL.path,
                                                Int32(threads), &error, error.count) else {
            throw SoundError.message("EfficientAT 加载失败：" + String(cString: error))
        }
        handle = loaded
    }

    deinit { SoundEfficientATRelease(handle) }

    /// Numerical check against the upstream PyTorch frontend; not used by the UI.
    func extractFeatures(samples: [Float], sampleRate: Int) throws -> [Float] {
        guard sampleRate == 32_000, samples.count == 320_000 else {
            throw SoundError.message("EfficientAT 前处理校验需要固定 10 秒、32 kHz 单声道输入。")
        }
        var features = [Float](repeating: 0, count: 128 * 1000)
        var error = [CChar](repeating: 0, count: 2048)
        guard SoundEfficientATExtract(handle, samples, samples.count, &features,
                                      features.count, &error, error.count) == 1 else {
            throw SoundError.message("EfficientAT 前处理失败：" + String(cString: error))
        }
        return features
    }

    func classify(samples: [Float], sampleRate: Int) throws -> [RawScore] {
        guard sampleRate == 32_000, samples.count == 320_000 else {
            throw SoundError.message("EfficientAT mn10_as 需要固定 10 秒、32 kHz 单声道输入。")
        }
        var scores = [Float](repeating: 0, count: 527)
        var error = [CChar](repeating: 0, count: 2048)
        guard SoundEfficientATRun(handle, samples, samples.count, &scores, scores.count, &error, error.count) == 1 else {
            throw SoundError.message("EfficientAT 推理失败：" + String(cString: error))
        }
        return try scores.enumerated().map { index, score in
            guard let label = labels[index], score.isFinite, (0...1).contains(score) else {
                throw SoundError.message("EfficientAT 返回无效的类别或分数。")
            }
            return RawScore(index: index, label: label, score: Double(score))
        }
    }
}

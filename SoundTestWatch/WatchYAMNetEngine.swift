import CoreML
import Foundation

struct WatchYAMNetResult {
    /// All 521 scores retain YAMNet's own label order and original English names.
    let scores: [WatchRawScore]
    let preprocessingMilliseconds: Double
    let inferenceMilliseconds: Double
    var totalMilliseconds: Double { preprocessingMilliseconds + inferenceMilliseconds }
}

/// Locally runs the Core ML YAMNet classifier after its matching log-mel frontend.
/// Call from a serial background queue; model loading is deliberately outside each
/// window's measured preprocessing and inference times.
final class WatchYAMNetEngine {
    static let modelID = "yamnetCoreML"
    static let modelName = "YAMNet（Core ML）"

    private let model: MLModel
    private let frontend: YAMNetWatchFeatures
    private let labels: [String]

    convenience init(bundle: Bundle = .main) throws {
        let modelURL = bundle.url(forResource: "YAMNet", withExtension: "mlmodelc")
            ?? bundle.url(forResource: "YAMNet", withExtension: "mlmodelc", subdirectory: "Resources")
        let labelsURL = bundle.url(forResource: "yamnet_label_list", withExtension: "txt")
            ?? bundle.url(forResource: "yamnet_label_list", withExtension: "txt", subdirectory: "Resources")
        guard let modelURL, let labelsURL else {
            throw EngineError.missingResources
        }
        try self.init(modelURL: modelURL, labelsURL: labelsURL)
    }

    /// Explicit URLs also let the simulator and tests validate the exact bundle files.
    init(modelURL: URL, labelsURL: URL) throws {
        let text = try String(contentsOf: labelsURL, encoding: .utf8)
        let parsed = text.split(whereSeparator: \.isNewline).map(String.init)
        guard parsed.count == 521, parsed[69] == "Dog", parsed[494] == "Silence" else {
            throw EngineError.invalidLabels
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        let loaded = try MLModel(contentsOf: modelURL, configuration: configuration)
        guard let input = loaded.modelDescription.inputDescriptionsByName["features"]?.multiArrayConstraint,
              input.shape.map(\.intValue) == [1, 96, 64],
              input.dataType == .float16,
              let output = loaded.modelDescription.outputDescriptionsByName["Identity"]?.multiArrayConstraint,
              output.shape.map(\.intValue) == [1, 521] else {
            throw EngineError.invalidModelInterface
        }
        model = loaded
        frontend = try YAMNetWatchFeatures()
        labels = parsed
    }

    func classify(samples: [Float], sampleRate: Int) throws -> WatchYAMNetResult {
        guard sampleRate == YAMNetWatchFeatures.sampleRate,
              samples.count == YAMNetWatchFeatures.sampleCount else {
            throw EngineError.invalidAudioFormat
        }
        let start = ProcessInfo.processInfo.systemUptime
        let features = try frontend.makeInput(samples: samples)
        let preprocessedAt = ProcessInfo.processInfo.systemUptime
        let provider = try MLDictionaryFeatureProvider(dictionary: [
            "features": MLFeatureValue(multiArray: features)
        ])
        let prediction = try model.prediction(from: provider)
        let inferredAt = ProcessInfo.processInfo.systemUptime
        guard let array = prediction.featureValue(for: "Identity")?.multiArrayValue,
              array.count == labels.count else {
            throw EngineError.invalidOutput
        }
        let scores = labels.indices.map { index in
            WatchRawScore(label: labels[index], score: array[index].doubleValue)
        }
        guard scores.allSatisfy({ $0.score.isFinite && (0...1).contains($0.score) }) else {
            throw EngineError.invalidOutput
        }
        return WatchYAMNetResult(
            scores: scores,
            preprocessingMilliseconds: (preprocessedAt - start) * 1_000,
            inferenceMilliseconds: (inferredAt - preprocessedAt) * 1_000
        )
    }

    enum EngineError: LocalizedError {
        case missingResources
        case invalidLabels
        case invalidModelInterface
        case invalidAudioFormat
        case invalidOutput

        var errorDescription: String? {
            switch self {
            case .missingResources: return "Apple Watch 缺少 YAMNet Core ML 模型或 521 类标签。"
            case .invalidLabels: return "YAMNet 标签数量或顺序校验失败。"
            case .invalidModelInterface: return "YAMNet Core ML 输入输出接口与当前版本不符。"
            case .invalidAudioFormat: return "YAMNet 需要 16 kHz、15,600 个单声道 Float PCM 样本。"
            case .invalidOutput: return "YAMNet Core ML 未返回完整的 521 类有限分数。"
            }
        }
    }
}

import Foundation
import SherpaTagging

/// Call only on the analysis queue. Each window owns a fresh stream; model weights
/// remain loaded until this object is released. There is no speech VAD in this path.
final class SherpaTagger: TaggingEngine {
    private let tagger: OpaquePointer
    private let labels: [Int: String]

    init(modelID: SoundModelID, modelURL: URL, labelsURL: URL, threads: Int) throws {
        guard [.zipformer, .cedTiny, .cedMini].contains(modelID) else { throw SherpaTaggerError.invalidModel }
        guard FileManager.default.isReadableFile(atPath: modelURL.path),
              FileManager.default.isReadableFile(atPath: labelsURL.path) else {
            throw SherpaTaggerError.missingFiles
        }
        labels = try Self.readLabels(labelsURL)
        guard labels.count == 527, Set(labels.keys) == Set(0..<527) else {
            throw SherpaTaggerError.invalidLabels
        }
        var config = SherpaOnnxAudioTaggingConfig()
        config.model.num_threads = Int32(max(1, min(threads, 8)))
        config.model.debug = 0
        config.top_k = 527
        let created = modelURL.path.withCString { modelPath in
            labelsURL.path.withCString { labelsPath in
                "cpu".withCString { provider in
                    if modelID == .zipformer { config.model.zipformer.model = modelPath }
                    else { config.model.ced = modelPath }
                    config.labels = labelsPath
                    config.model.provider = provider
                    return SherpaOnnxCreateAudioTagging(&config)
                }
            }
        }
        guard let created else { throw SherpaTaggerError.loadFailed }
        tagger = created
    }

    deinit { SherpaOnnxDestroyAudioTagging(tagger) }

    func classify(samples: [Float], sampleRate: Int) throws -> [RawScore] {
        // App policy: do not send empty/very short windows into native graph ops.
        // This is a validated input limit, not a claim of temporal resolution.
        guard sampleRate >= 8_000, sampleRate <= 192_000,
              samples.count >= sampleRate, samples.count <= Int(Int32.max),
              samples.allSatisfy({ $0.isFinite }) else {
            throw SherpaTaggerError.invalidAudio
        }
        guard let stream = SherpaOnnxAudioTaggingCreateOfflineStream(tagger) else {
            throw SherpaTaggerError.streamFailed
        }
        defer { SherpaOnnxDestroyOfflineStream(stream) }
        samples.withUnsafeBufferPointer { buffer in
            SherpaOnnxAcceptWaveformOffline(stream, Int32(sampleRate), buffer.baseAddress, Int32(buffer.count))
        }
        guard let result = SherpaOnnxAudioTaggingCompute(tagger, stream, 527) else {
            throw SherpaTaggerError.inferenceFailed
        }
        defer { SherpaOnnxAudioTaggingFreeResults(result) }
        var scores: [RawScore] = []
        scores.reserveCapacity(527)
        var seen = Set<Int>()
        for offset in 0..<527 {
            guard let event = result[offset], let name = event.pointee.name else {
                throw SherpaTaggerError.incompleteResults
            }
            let index = Int(event.pointee.index)
            let label = String(cString: name)
            let score = Double(event.pointee.prob)
            guard score.isFinite, labels[index] == label, seen.insert(index).inserted else {
                throw SherpaTaggerError.incompleteResults
            }
            scores.append(RawScore(index: index, label: label, score: score))
        }
        return scores.sorted { $0.index < $1.index }
    }

    static func readLabels(_ url: URL) throws -> [Int: String] {
        let text = try String(contentsOf: url, encoding: .utf8)
        var labels: [Int: String] = [:]
        for line in text.split(whereSeparator: \.isNewline).dropFirst() {
            let fields = parseCSVRow(String(line))
            guard fields.count == 3, let index = Int(fields[0]),
                  labels[index] == nil, !fields[2].isEmpty else {
                throw SherpaTaggerError.invalidLabels
            }
            labels[index] = fields[2]
        }
        return labels
    }

    private static func parseCSVRow(_ row: String) -> [String] {
        var fields: [String] = [], field = "", quoted = false
        var iterator = row.makeIterator()
        // CSV names can contain commas. Paired labels use standard quoted fields.
        while let character = iterator.next() {
            if character == "\"" { quoted.toggle() }
            else if character == "," && !quoted { fields.append(field); field = "" }
            else { field.append(character) }
        }
        fields.append(field)
        return fields
    }
}

private enum SherpaTaggerError: LocalizedError {
    case invalidModel, missingFiles, invalidLabels, loadFailed, invalidAudio
    case streamFailed, inferenceFailed, incompleteResults
    var errorDescription: String? {
        switch self {
        case .invalidModel: return "模型与 sherpa-onnx Audio Tagging 引擎不匹配。"
        case .missingFiles: return "缺少内置模型或配套类别表，请重新构建安装。"
        case .invalidLabels: return "类别表无效：需要 527 个不重复的原始标签。"
        case .loadFailed: return "sherpa-onnx 声音分类模型加载失败。"
        case .invalidAudio: return "分析音频需至少 1 秒，采样率为 8–192 kHz，且样本必须为有限数值。"
        case .streamFailed: return "无法创建声音分类分析窗口。"
        case .inferenceFailed: return "sherpa-onnx 未返回分类结果。"
        case .incompleteResults: return "模型返回的类别或分数不完整，本窗口不生成事件提示。"
        }
    }
}

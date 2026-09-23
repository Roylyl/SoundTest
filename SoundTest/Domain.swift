import Foundation

enum SoundError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

struct RawScore: Codable, Sendable, Identifiable {
    let index: Int
    let label: String
    let score: Double
    var id: Int { index }
    init(index: Int, label: String, score: Double) { self.index = index; self.label = label; self.score = score }
    // Compact, self-contained JSON triples [class index, original label, raw score].
    init(from decoder: Decoder) throws {
        var values = try decoder.unkeyedContainer()
        index = try values.decode(Int.self); label = try values.decode(String.self); score = try values.decode(Double.self)
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.unkeyedContainer()
        try values.encode(index); try values.encode(label); try values.encode(score)
    }
}

protocol TaggingEngine: AnyObject {
    func classify(samples: [Float], sampleRate: Int) throws -> [RawScore]
}

enum SoundModelID: String, CaseIterable, Codable, Identifiable, Sendable {
    case zipformer, cedTiny, cedMini, yamnet, efficientAT, cpMobile
    var id: String { rawValue }
    var title: String {
        switch self {
        case .zipformer: return "Zipformer-small INT8"
        case .cedTiny: return "CED-Tiny INT8"
        case .cedMini: return "CED-Mini INT8"
        case .yamnet: return "YAMNet"
        case .efficientAT: return "EfficientAT mn10_as"
        case .cpMobile: return "CP-Mobile 通用场景模型"
        }
    }
    var number: String { ["zipformer":"M01", "cedTiny":"M02", "cedMini":"M03", "yamnet":"M04", "efficientAT":"M05", "cpMobile":"ASC01"][rawValue]! }
    var framework: String {
        switch self {
        case .cpMobile: return "ONNX Runtime · CP-Mobile"
        case .efficientAT: return "ONNX Runtime · EfficientAT"
        case .yamnet: return "TensorFlow Lite C"
        default: return "sherpa-onnx Audio Tagging"
        }
    }
    var defaultWindow: Double { self == .cpMobile ? 1 : self == .yamnet ? 0.975 : 10 }
    var defaultStep: Double { self == .cpMobile ? 1 : self == .yamnet ? 0.48 : 2 }
    var expectedCount: Int { self == .cpMobile ? 10 : self == .yamnet ? 521 : 527 }
}

enum AnalysisMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case segment = "单段识别", continuous = "连续分窗"
    var id: String { rawValue }
}

enum InputMethod: String, CaseIterable, Codable, Identifiable, Sendable {
    case environment = "真实环境采集", playback = "扬声器回放录音", file = "直接导入"
    var id: String { rawValue }
}

struct SoundOptions: Codable, Equatable, Sendable {
    var mode: AnalysisMode = .segment
    var windowSeconds = 10.0
    var stepSeconds = 2.0
    var mergeGapSeconds = 0.0
    var threads = 2
    var thresholds: [String: Double] = Dictionary(uniqueKeysWithValues: TargetCategory.all.map { ($0.id, 0.3) })
    var scene: SceneOptions? = nil
    var mappingVersion = "soundtest-zh-v1"
    func validated(for model: SoundModelID) throws -> SoundOptions {
        guard windowSeconds.isFinite, stepSeconds.isFinite, mergeGapSeconds.isFinite,
              windowSeconds >= 0.975, windowSeconds <= 30,
              stepSeconds >= 0.24, stepSeconds <= windowSeconds,
              mergeGapSeconds >= 0, mergeGapSeconds <= 5, (1...4).contains(threads),
              thresholds.values.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }),
              TargetCategory.all.allSatisfy({ thresholds[$0.id] != nil }) else {
            throw SoundError.message("分析参数无效，请恢复模型默认设置。")
        }
        if model == .cpMobile {
            guard abs(windowSeconds - 1) < 0.00001, [0.5, 1.0].contains(stepSeconds), (scene ?? SceneOptions()).valid else { throw SoundError.message("场景模型固定1秒窗口，步长0.5或1秒；请检查平滑设置。") }
        }
        if model == .yamnet && abs(windowSeconds - 0.975) > 0.00001 {
            throw SoundError.message("YAMNet 使用固定 0.975 秒原生输入窗口。")
        }
        if model == .efficientAT && abs(windowSeconds - 10) > 0.00001 {
            throw SoundError.message("EfficientAT mn10_as 本版使用固定 10 秒输入窗口。")
        }
        if model != .yamnet && windowSeconds < 1 { throw SoundError.message("分析窗口至少为1秒。") }
        var result = self
        result.mappingVersion = model == .cpMobile ? "soundtest-asc-zh-v1" : "soundtest-zh-v1"
        return result
    }
}

struct TargetCategory: Identifiable, Sendable {
    let id: String
    let chinese: String
    let labels: [String]
    // Exact labels, resolved in each model's own class list. Broad parent classes such as
    // Dog and Cat stay visible in raw scores but do not count as a vocalization hit.
    static let all = [
        TargetCategory(id: "petVocalization", chinese: "猫狗叫声", labels: [
            "Bark", "Yip", "Howl", "Bow-wow", "Growling", "Whimper (dog)",
            "Purr", "Meow", "Hiss", "Caterwaul"
        ]),
        TargetCategory(id: "cough", chinese: "咳嗽", labels: ["Cough"]),
        TargetCategory(id: "laughter", chinese: "笑声", labels: [
            "Laughter", "Baby laughter", "Giggle", "Snicker", "Belly laugh", "Chuckle, chortle"
        ]),
        TargetCategory(id: "applause", chinese: "鼓掌", labels: ["Clapping", "Applause"])
    ]
}

struct TargetScore: Codable, Sendable, Identifiable {
    let id: String
    let chinese: String
    let score: Double?
    let originalLabel: String?
    let threshold: Double
    var prompted: Bool { score.map { $0 >= threshold } ?? false }
}

struct WindowResult: Codable, Sendable, Identifiable {
    var id = UUID().uuidString
    let index: Int
    let start: Double
    let end: Double
    let modelInputSeconds: Double
    let paddedSeconds: Double
    let scores: [RawScore]
    let targets: [TargetScore]
    let inferenceMS: Double
    let processingFinishedAt: Date
    var presentedAt: Date?
    // Live acquisition time and queue/UI delay have separate meanings; file runs use nil.
    let windowCollectionSeconds: Double?
    var additionalAudioWaitMS: Double? = nil
    let queueDelayMS: Double?
    var promptAfterWindowMS: Double?
    var trueEventLatencyMS: Double? = nil
    var scene: ScenePrediction? = nil
    var top5: [RawScore] { Array(scores.sorted { $0.score > $1.score }.prefix(5)) }
}

struct EventEstimate: Codable, Sendable, Identifiable {
    var id = UUID().uuidString
    let categoryID: String
    let chinese: String
    var evidenceStart: Double
    var evidenceEnd: Double
    var estimatedStart: Double
    var estimatedEnd: Double
    var peakScore: Double
    var windowIndices: [Int]
    var method = "以阳性窗口中心±步长/2估计，再按同类间隔合并；不是精确事件边界"
}

struct ModelResource: Codable, Sendable {
    let path: String
    let bytes: Int64
    let sha256: String
    let source: String
}

struct SoundModelAsset: Codable, Sendable, Identifiable {
    let id: String
    let revision: String
    let frameworkVersion: String
    let source: String
    let license: String
    let modelFile: String
    let labelsFile: String
    let files: [ModelResource]
    var bytes: Int64 { files.reduce(0) { $0 + $1.bytes } }
}

struct MaterialInfo: Codable, Sendable {
    var testCaseVersion: String? = "soundtest-s01-s17-v2"
    var testCase = "S01"
    var sampleID = ""
    var filename: String?
    var sha256: String?
    var source = ""
    var permission = ""
    var manualLabel = ""
    var inputMethod: InputMethod = .environment
    var originalSampleRate: Double?
    var originalChannels: Int?
    var savedAudioName: String?
}

struct SoundRecord: Codable, Identifiable, Sendable {
    var schemaVersion = 2
    // Optional additive metadata: legacy schema 1/2 single-file records still decode.
    var batch: BatchRecordLink? = nil
    var taskType: SoundTask? = nil
    var effectiveTask: SoundTask { taskType ?? model.task }
    var id = UUID().uuidString
    var startedAt = Date()
    var endedAt: Date?
    var appVersion = "2.0.0"
    let model: SoundModelID
    let asset: SoundModelAsset
    let options: SoundOptions
    let device: String
    var actualInput: String
    var actualInputUID: String
    var material: MaterialInfo
    var audioSeconds = 0.0
    var modelSampleRate = 16000
    var loadMS = 0.0
    var inferenceMS = 0.0
    var stopWaitMS: Double?
    var status = "进行中"
    var error: String?
    var thermalStart = ""
    var thermalEnd = ""
    var batteryStart: Float?
    var windows: [WindowResult] = []
    var events: [EventEstimate] = []
    var anomalies: [String] = []
    var metricDefinition = "inferenceMS仅模型classify调用；windowCollectionSeconds为有效窗口覆盖时长；additionalAudioWaitMS为上次分析结束后等待本窗新音频的估计时长（已积压时为0）；queueDelayMS为窗口就绪至推理开始；promptAfterWindowMS为有效窗尾到UI提示（含调用/队列/UI）。采集时钟以录音gate开启时刻近似锚定，不能消除硬件缓冲延迟。真实声源起点未知，trueEventLatencyMS留空。分数不是准确率。文件时间线按音频位置，不按计算速度。"
}

struct SoundTestCase: Identifiable {
    let id: String
    let name: String
    static let all: [SoundTestCase] = zip(1...17, [
        "猫叫", "狗叫", "咳嗽", "笑声", "鼓掌", "静音与普通无目标", "猫狗易混淆声",
        "咳嗽易混淆声", "笑声易混淆声", "鼓掌易混淆声", "目标叠加背景",
        "不同目标先后出现", "两个目标同时出现", "短声、窗边界与文件尾",
        "同类连续与间隔", "长时无目标运行", "长时背景插入目标"
    ]).map { SoundTestCase(id: String(format: "S%02d", $0.0), name: $0.1) }
}

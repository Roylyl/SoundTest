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
    case zipformer, cedTiny, cedMini, yamnet
    var id: String { rawValue }
    var title: String {
        switch self {
        case .zipformer: return "Zipformer-small INT8"
        case .cedTiny: return "CED-Tiny INT8"
        case .cedMini: return "CED-Mini INT8"
        case .yamnet: return "YAMNet"
        }
    }
    var number: String { ["zipformer":"M01", "cedTiny":"M02", "cedMini":"M03", "yamnet":"M04"][rawValue]! }
    var framework: String { self == .yamnet ? "TensorFlow Lite C" : "sherpa-onnx Audio Tagging" }
    var defaultWindow: Double { self == .yamnet ? 0.975 : 10 }
    var defaultStep: Double { self == .yamnet ? 0.48 : 2 }
    var expectedCount: Int { self == .yamnet ? 521 : 527 }
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
    var includeExtensions = false
    var thresholds: [String: Double] = Dictionary(uniqueKeysWithValues: TargetCategory.all.map { ($0.id, 0.3) })
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
        if model == .yamnet && abs(windowSeconds - 0.975) > 0.00001 {
            throw SoundError.message("YAMNet 使用固定 0.975 秒原生输入窗口。")
        }
        if model != .yamnet && windowSeconds < 1 { throw SoundError.message("sherpa 分析窗口至少为1秒。") }
        return self
    }
}

struct TargetCategory: Identifiable, Sendable {
    let id: String
    let chinese: String
    let labels: [String]
    let primary: Bool
    // Exact labels, resolved in each model's own class list. Parent classes stay separate.
    static let all = [
        TargetCategory(id: "knock", chinese: "敲击（含敲门）", labels: ["Knock"], primary: true),
        TargetCategory(id: "bark", chinese: "狗叫", labels: ["Bark"], primary: true),
        TargetCategory(id: "cough", chinese: "咳嗽", labels: ["Cough"], primary: true),
        TargetCategory(id: "horn", chinese: "汽车喇叭", labels: ["Vehicle horn, car horn, honking"], primary: true),
        TargetCategory(id: "doorbell", chinese: "门铃", labels: ["Doorbell"], primary: false),
        TargetCategory(id: "alarm", chinese: "警报", labels: ["Alarm"], primary: false),
        TargetCategory(id: "water", chinese: "流水", labels: ["Water", "Water tap, faucet"], primary: false),
        TargetCategory(id: "baby", chinese: "婴儿哭", labels: ["Baby cry, infant cry"], primary: false),
        TargetCategory(id: "impact", chinese: "撞击声（不判定跌倒）", labels: ["Thump, thud"], primary: false)
    ]
}

struct TargetScore: Codable, Sendable, Identifiable {
    let id: String
    let chinese: String
    let score: Double?
    let originalLabel: String?
    let threshold: Double
    var enabled = true
    var prompted: Bool { enabled && (score.map { $0 >= threshold } ?? false) }
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
    var schemaVersion = 1
    var id = UUID().uuidString
    var startedAt = Date()
    var endedAt: Date?
    var appVersion = "1.0.0"
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
    static let all: [SoundTestCase] = zip(1...17, ["敲门", "狗叫", "咳嗽", "汽车喇叭", "背景噪声", "无目标 / 静音", "离线冷启动与切换", "重复启停与切换", "易混淆声音", "距离与朝向", "声音先后顺序", "多事件重叠", "短事件与窗口边界", "同文件与格式对照", "连续运行", "权限、输入与中断", "日志与导出"]).map { SoundTestCase(id: String(format: "S%02d", $0.0), name: $0.1) }
}

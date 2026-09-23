import Foundation

// Watch logs deliberately use a separate schema. They are never decoded as iPhone SoundRecord values.
struct WatchRawScore: Codable, Sendable {
    let label: String
    let score: Double
}

struct WatchTargetScore: Codable, Sendable {
    let name: String
    let label: String?
    let score: Double?
    let prompted: Bool
}

struct WatchWindowLog: Codable, Sendable {
    let index: Int
    let start: Double
    let end: Double
    let scores: [WatchRawScore]
    let targets: [WatchTargetScore]
}

struct WatchTestLog: Codable, Identifiable, Sendable {
    let schemaVersion: Int
    let id: String
    let startedAt: Date
    let endedAt: Date
    let modelID: String
    let modelName: String
    let device: String
    let input: String
    let status: String
    let error: String?
    let threshold: Double
    let audioSeconds: Double
    // Sound Analysis does not expose the model's inference-only time.
    let inferenceMS: Double?
    let windows: [WatchWindowLog]

    static let currentSchemaVersion = 1
    static let systemModelID = "appleSoundAnalysisV1"
    static let systemModelName = "Apple Sound Analysis（系统模型）"
}

enum WatchLogStore {
    static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WatchLogs", isDirectory: true)
    }

    static func fileURL(for id: String) -> URL? {
        guard UUID(uuidString: id) != nil else { return nil }
        return directory.appendingPathComponent(id).appendingPathExtension("json")
    }

    static func save(_ log: WatchTestLog) throws {
        guard log.schemaVersion == WatchTestLog.currentSchemaVersion,
              let file = fileURL(for: log.id) else {
            throw NSError(domain: "SoundTestWatch.Log", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "手表日志标识或版本无效。"])
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(log).write(to: file, options: .atomic)
    }

    static func all() -> [WatchTestLog] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        ) else { return [] }
        return files.compactMap { file in
            guard file.pathExtension == "json",
                  UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil,
                  let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  (values.fileSize ?? 0) <= 64_000_000,
                  let data = try? Data(contentsOf: file),
                  let log = try? JSONDecoder().decode(WatchTestLog.self, from: data),
                  log.schemaVersion == WatchTestLog.currentSchemaVersion,
                  log.id == file.deletingPathExtension().lastPathComponent else { return nil }
            return log
        }.sorted { $0.startedAt > $1.startedAt }
    }
}

struct WatchModelChoice: Identifiable {
    let id: String
    let name: String
    let detail: String
    let available: Bool

    static let all: [WatchModelChoice] = [
        .init(id: WatchTestLog.systemModelID, name: WatchTestLog.systemModelName,
              detail: "在 Apple Watch 本地运行；与 iPhone 开源模型分开记录。", available: true),
        .init(id: "zipformer", name: "Zipformer-small INT8", detail: "现有 sherpa-onnx 库仅含 iOS 构建。", available: false),
        .init(id: "cedTiny", name: "CED-Tiny INT8", detail: "现有 sherpa-onnx 库仅含 iOS 构建。", available: false),
        .init(id: "cedMini", name: "CED-Mini INT8", detail: "现有 sherpa-onnx 库仅含 iOS 构建。", available: false),
        .init(id: WatchYAMNetEngine.modelID, name: WatchYAMNetEngine.modelName,
              detail: "Core ML 与声学前处理均在手表本地运行；真机性能待测。", available: true),
        .init(id: "efficientAT", name: "EfficientAT mn10_as", detail: "现有 ONNX Runtime 库仅含 iOS 构建。", available: false),
        .init(id: "cpMobile", name: "CP-Mobile", detail: "现有 ONNX Runtime 库仅含 iOS 构建。", available: false)
    ]
}

enum WatchTarget: CaseIterable {
    case pet, cough, laughter, applause

    var name: String {
        switch self {
        case .pet: return "猫狗叫声"
        case .cough: return "咳嗽"
        case .laughter: return "笑声"
        case .applause: return "鼓掌"
        }
    }

    // Exact sound-event labels only. The broad cat/dog parent classes are not a vocalization hit.
    var labels: [String] {
        switch self {
        case .pet: return ["dog_bark", "dog_howl", "dog_bow_wow", "dog_growl", "dog_whimper",
                           "cat_meow", "cat_purr", "cat_hiss", "cat_caterwaul"]
        case .cough: return ["cough"]
        case .laughter: return ["laughter", "baby_laughter", "belly_laugh", "giggle", "snicker"]
        case .applause: return ["clapping", "applause"]
        }
    }
}

// UUID path validation, local JSON persistence and damaged-record tolerance adapted from ASRtest.
import Foundation

struct SoundSessionStore {
    static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Sessions", isDirectory: true)
    }
    static func url(_ id: String) -> URL {
        directory.appendingPathComponent(UUID(uuidString: id) == nil ? "invalid-session" : id).appendingPathExtension("json")
    }
    static func save(_ record: SoundRecord) throws {
        guard UUID(uuidString: record.id) != nil, (1...2).contains(record.schemaVersion) else { throw SoundError.message("日志标识或版本无效。") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var location = directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try location.setResourceValues(values)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(record).write(to: url(record.id), options: [.atomic, .completeFileProtectionUnlessOpen])
        var summary = record; summary.windows = []; summary.events = []
        try encoder.encode(summary).write(to: summaryURL(record.id), options: [.atomic, .completeFileProtectionUnlessOpen])
    }
    private static func summaryURL(_ id: String) -> URL { url(id).deletingPathExtension().appendingPathExtension("summary.json") }
    static func load(_ id: String) throws -> SoundRecord {
        guard UUID(uuidString: id) != nil else { throw SoundError.message("日志标识无效。") }
        let file = url(id)
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) <= 512_000_000 else { throw SoundError.message("日志损坏或大小超出可读取范围。") }
        let record = try JSONDecoder().decode(SoundRecord.self, from: Data(contentsOf: file))
        guard record.id == id, (1...2).contains(record.schemaVersion) else { throw SoundError.message("日志标识或版本不匹配。") }
        return record
    }
    static func all() -> [SoundRecord] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory,
                    includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) else { return [] }
        return files.filter { $0.lastPathComponent.hasSuffix(".summary.json") }.compactMap { file in
            guard let v = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  v.isRegularFile == true, v.isSymbolicLink != true, (v.fileSize ?? 0) <= 1_000_000,
                  let data = try? Data(contentsOf: file), let record = try? JSONDecoder().decode(SoundRecord.self, from: data),
                  (1...2).contains(record.schemaVersion), UUID(uuidString: record.id) != nil,
                  file.deletingPathExtension().deletingPathExtension().lastPathComponent == record.id,
                  FileManager.default.fileExists(atPath: url(record.id).path) else { return nil }
            return record
        }.sorted { $0.startedAt > $1.startedAt }
    }
    static func delete(_ record: SoundRecord) throws {
        guard UUID(uuidString: record.id) != nil else { throw SoundError.message("日志标识无效。") }
        if FileManager.default.fileExists(atPath: url(record.id).path) { try FileManager.default.removeItem(at: url(record.id)) }
        if FileManager.default.fileExists(atPath: summaryURL(record.id).path) { try FileManager.default.removeItem(at: summaryURL(record.id)) }
    }
    /// The optional location exists for isolated filesystem tests. Production callers
    /// clear only Sessions; imported audio, Samples and model files live elsewhere.
    static func clear(at location: URL = directory) throws {
        if FileManager.default.fileExists(atPath: location.path) { try FileManager.default.removeItem(at: location) }
    }
}

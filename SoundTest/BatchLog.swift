import Foundation

/// Publish groups and records together so List never observes a half-updated deletion.
struct SoundHistorySnapshot {
    var records: [SoundRecord] = []
    var groups: [BatchLogGroup] = []
}

struct BatchRecordLink: Codable, Sendable {
    let groupID: String
    let itemID: String
    let index: Int
    let total: Int
}

enum BatchItemStatus: String, Codable, Sendable {
    case queued = "待分析", preparing = "读取中", analyzing = "分析中"
    case completed = "完成", failed = "失败", stopped = "已停止", skipped = "未运行"
    var isTerminal: Bool { self == .completed || self == .failed || self == .stopped || self == .skipped }
}

struct BatchLogItem: Codable, Identifiable, Sendable {
    let id: String
    let filename: String
    var status: BatchItemStatus = .queued
    var recordID: String?
    var error: String?
    var audioSeconds: Double?
    var inferenceMS: Double?
}

enum BatchGroupStatus: String, Codable, Sendable {
    case running = "进行中", completed = "已完成", stopped = "已停止", interrupted = "运行中断"
}

struct BatchLogGroup: Codable, Identifiable, Sendable {
    var schemaVersion = 1
    var id = UUID().uuidString
    var name: String
    var startedAt = Date()
    var endedAt: Date?
    let model: SoundModelID
    let options: SoundOptions
    var status: BatchGroupStatus = .running
    var stopReason: String?
    var items: [BatchLogItem]
    var completedCount: Int { items.filter { $0.status == .completed }.count }
    var failedCount: Int { items.filter { $0.status == .failed }.count }
    var finishedCount: Int { items.filter { $0.status.isTerminal }.count }
    var audioSeconds: Double { items.compactMap(\.audioSeconds).reduce(0, +) }
    var inferenceMS: Double { items.compactMap(\.inferenceMS).reduce(0, +) }
    var summary: String {
        let unfinished = items.filter { $0.status == .stopped || $0.status == .skipped }.count
        return "成功 \(completedCount) · 失败 \(failedCount)" + (unfinished > 0 ? " · 停止或未运行 \(unfinished)" : "")
    }

    mutating func stopUnfinished(reason: String, at date: Date = Date(), interrupted: Bool = false) {
        status = interrupted ? .interrupted : .stopped; stopReason = reason; endedAt = date
        for index in items.indices where !items[index].status.isTerminal {
            items[index].status = items[index].status == .queued ? .skipped : .stopped
            items[index].error = reason
        }
    }
}

enum BatchLogStore {
    static var directory: URL { SoundSessionStore.directory.appendingPathComponent("BatchGroups", isDirectory: true) }
    static var exportDirectory: URL { FileManager.default.temporaryDirectory.appendingPathComponent("SoundTest-BatchExports", isDirectory: true) }
    static func url(_ id: String) throws -> URL {
        guard UUID(uuidString: id) != nil else { throw SoundError.message("日志组标识无效。") }
        return directory.appendingPathComponent(id).appendingPathExtension("json")
    }
    static func save(_ group: BatchLogGroup) throws {
        try validate(group)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var folder = directory; var values = URLResourceValues(); values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(group).write(to: url(group.id), options: [.atomic, .completeFileProtectionUnlessOpen])
    }
    static func load(_ id: String) throws -> BatchLogGroup {
        let path = try url(id)
        let info = try path.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true, (info.fileSize ?? 0) <= 2_000_000 else {
            throw SoundError.message("日志组文件无效或过大。")
        }
        let group = try JSONDecoder().decode(BatchLogGroup.self, from: Data(contentsOf: path))
        try validate(group)
        guard group.id == id else { throw SoundError.message("日志组标识不匹配。") }
        return group
    }
    private static func validate(_ group: BatchLogGroup) throws {
        guard group.schemaVersion == 1, UUID(uuidString: group.id) != nil,
              (1...BatchImport.maximumFiles).contains(group.items.count),
              Set(group.items.map(\.id)).count == group.items.count,
              group.items.allSatisfy({ UUID(uuidString: $0.id) != nil && ($0.recordID == nil || UUID(uuidString: $0.recordID!) != nil) }) else {
            throw SoundError.message("日志组内容或版本无效。")
        }
    }
    static func all() -> [BatchLogGroup] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { try? load($0.deletingPathExtension().lastPathComponent) }
            .sorted { $0.startedAt > $1.startedAt }
    }
    /// Called once at launch; never leave an old process's group marked as running.
    static func recoverInterrupted() throws {
        for var group in all() where group.status == .running {
            for index in group.items.indices where !group.items[index].status.isTerminal {
                if let id = group.items[index].recordID, let record = try? SoundSessionStore.load(id),
                   record.batch?.groupID == group.id, record.batch?.itemID == group.items[index].id {
                    group.items[index].status = record.error == nil ? .completed : .failed
                    group.items[index].error = record.error
                    group.items[index].audioSeconds = record.audioSeconds
                    group.items[index].inferenceMS = record.inferenceMS
                } else { group.items[index].recordID = nil }
            }
            group.stopUnfinished(reason: "上次运行未正常结束；保留已保存结果，未自动继续分析。", interrupted: true)
            try save(group)
        }
    }
    static func delete(_ id: String) throws {
        guard FileManager.default.fileExists(atPath: try url(id).path) else { return }
        let group = try load(id)
        // Verify ownership before deleting any record; a damaged manifest must not delete other runs.
        let records = try group.items.compactMap { item -> SoundRecord? in
            guard let recordID = item.recordID, FileManager.default.fileExists(atPath: SoundSessionStore.url(recordID).path) else { return nil }
            let record = try SoundSessionStore.load(recordID)
            guard record.batch?.groupID == id, record.batch?.itemID == item.id else { throw SoundError.message("记录与日志组不匹配，已取消删除。") }
            return record
        }
        for record in records { try SoundSessionStore.delete(record) }
        try FileManager.default.removeItem(at: url(id))
    }
    /// Export one JSON with the group manifest and full per-file records. Read one
    /// record at a time so a large batch does not load every window into RAM at once.
    static func export(_ id: String) throws -> URL {
        let group = try load(id)
        guard group.status != .running else { throw SoundError.message("请等待本轮结束后分享整组日志。") }
        let directory = exportDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appendingPathComponent("SoundTest-batch-\(id).json")
        let temporary = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("tmp")
        FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.protectionKey: FileProtectionType.completeUnlessOpen])
        defer { try? FileManager.default.removeItem(at: temporary) }
        let handle = try FileHandle(forWritingTo: temporary)
        defer { try? handle.close() }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try handle.write(contentsOf: Data("{\"group\":".utf8))
        try handle.write(contentsOf: encoder.encode(group))
        try handle.write(contentsOf: Data(",\"records\":[".utf8))
        var first = true
        for item in group.items {
            guard let recordID = item.recordID else { continue }
            let record = try SoundSessionStore.load(recordID)
            guard record.batch?.groupID == id, record.batch?.itemID == item.id else { throw SoundError.message("记录与日志组不匹配，无法导出。") }
            if !first { try handle.write(contentsOf: Data(",".utf8)) }; first = false
            try handle.write(contentsOf: encoder.encode(record))
        }
        try handle.write(contentsOf: Data("]}".utf8)); try handle.synchronize(); try handle.close()
        if FileManager.default.fileExists(atPath: output.path) { _ = try FileManager.default.replaceItemAt(output, withItemAt: temporary) }
        else { try FileManager.default.moveItem(at: temporary, to: output) }
        return output
    }
}

import Foundation

/// Takes a byte-for-byte snapshot of saved logs. Call on the history queue, while
/// recording and history mutations are disabled, so groups and records agree.
enum AllLogsExport {
    static var directory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("SoundTest-AllLogsExports", isDirectory: true)
    }

    private static let jobPrefix = "SoundTest-Export-"
    private static let ownershipFile = ".soundtest-export"
    private static let archivePrefix = "SoundTest-all-logs-"
    private static let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]

    enum ExportError: LocalizedError {
        case empty, unsafeFile, invalidDestination, archiveUnavailable
        var errorDescription: String? {
            switch self {
            case .empty: return "暂无可导出的完整日志。"
            case .unsafeFile: return "日志目录中存在符号链接或不支持的文件，已取消导出。"
            case .invalidDestination: return "日志导出位置无效。"
            case .archiveUnavailable: return "未能生成日志 ZIP，请重试。"
            }
        }
    }

    static func create(sessionsDirectory: URL = SoundSessionStore.directory,
                       exportDirectory: URL = AllLogsExport.directory) throws -> URL {
        let manager = FileManager.default
        guard manager.fileExists(atPath: sessionsDirectory.path) else { throw ExportError.empty }
        let sourceInfo = try sessionsDirectory.resourceValues(forKeys: keys)
        guard sourceInfo.isDirectory == true, sourceInfo.isSymbolicLink != true else { throw ExportError.unsafeFile }

        // The output must never be inside the source tree (including path aliases).
        let sourcePath = sessionsDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        let outputPath = exportDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        guard outputPath != sourcePath, !outputPath.hasPrefix(sourcePath + "/") else {
            throw ExportError.invalidDestination
        }
        if manager.fileExists(atPath: exportDirectory.path) {
            let info = try exportDirectory.resourceValues(forKeys: keys)
            guard info.isDirectory == true, info.isSymbolicLink != true else { throw ExportError.invalidDestination }
        }
        let files = try logFiles(in: sessionsDirectory)
        guard !files.isEmpty else { throw ExportError.empty }

        let jobID = UUID().uuidString
        let job = exportDirectory.appendingPathComponent(jobPrefix + jobID, isDirectory: true)
        let snapshot = job.appendingPathComponent("SoundTest-Logs", isDirectory: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let output = job.appendingPathComponent("\(archivePrefix)\(formatter.string(from: Date()))-\(jobID.prefix(8)).zip")
        var completed = false
        defer {
            if !completed { try? manager.removeItem(at: job) }
        }
        try manager.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try Data(jobID.utf8).write(to: job.appendingPathComponent(ownershipFile), options: .atomic)
        let sessions = snapshot.appendingPathComponent("Sessions", isDirectory: true)
        try manager.createDirectory(at: sessions, withIntermediateDirectories: true)
        for file in files {
            // Do not decode or aggregate: preserves unknown/damaged JSON and all
            // window scores, including records absent from the UI summary cache.
            let info = try file.url.resourceValues(forKeys: keys)
            guard info.isRegularFile == true, info.isSymbolicLink != true else { throw ExportError.unsafeFile }
            let destination = sessions.appendingPathComponent(file.relativePath)
            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manager.copyItem(at: file.url, to: destination)
        }
        let instructions = """
        SoundTest 全部日志导出
        导出时间：\(ISO8601DateFormatter().string(from: Date()))
        完整 JSON 文件数：\(files.count)

        Sessions 内为导出时已保存的原始完整 JSON；BatchGroups 内为批量日志组清单。
        记录 ID、组 ID、窗口分数、耗时和异常字段均保留原内容。
        未按界面可见记录筛选；未知版本或损坏 JSON 也按原字节保留，供排查。
        不包含重复的 .summary.json 缓存、音频文件或模型文件。
        本 ZIP 是日志快照，不包含尚未保存的测试。导出不会修改或删除原日志。
        """
        try Data(instructions.utf8).write(to: snapshot.appendingPathComponent("README.txt"), options: .atomic)

        // Foundation's .forUploading makes a ZIP when the input is a directory.
        // Its temporary URL expires when the accessor returns, so copy it here.
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var copyError: Error?
        var copiedArchive = false
        coordinator.coordinate(readingItemAt: snapshot, options: .forUploading, error: &coordinationError) { archive in
            do {
                try manager.copyItem(at: archive, to: output)
                let handle = try FileHandle(forReadingFrom: output)
                defer { try? handle.close() }
                guard try handle.read(upToCount: 4) == Data([0x50, 0x4b, 0x03, 0x04]) else {
                    throw ExportError.archiveUnavailable
                }
                copiedArchive = true
            } catch { copyError = error }
        }
        if let coordinationError { throw coordinationError }
        if let copyError { throw copyError }
        guard copiedArchive else { throw ExportError.archiveUnavailable }
        try manager.removeItem(at: snapshot)
        completed = true
        return output
    }

    /// Only delete a completed export job created by this type. Never accept a
    /// source-log URL or recursively delete the shared export root.
    static func cleanup(_ url: URL) {
        let manager = FileManager.default
        let job = url.deletingLastPathComponent()
        guard url.lastPathComponent.hasPrefix(archivePrefix), job.lastPathComponent.hasPrefix(jobPrefix) else { return }
        let jobID = String(job.lastPathComponent.dropFirst(jobPrefix.count))
        guard UUID(uuidString: jobID) != nil, url.lastPathComponent.hasSuffix("-\(jobID.prefix(8)).zip"),
              let info = try? job.resourceValues(forKeys: keys), info.isDirectory == true, info.isSymbolicLink != true else { return }
        let marker = job.appendingPathComponent(ownershipFile)
        guard let markerInfo = try? marker.resourceValues(forKeys: keys), markerInfo.isRegularFile == true, markerInfo.isSymbolicLink != true,
              let ownership = try? String(contentsOf: marker, encoding: .utf8), ownership == jobID else { return }
        try? manager.removeItem(at: job)
    }

    private static func logFiles(in root: URL) throws -> [(url: URL, relativePath: String)] {
        let manager = FileManager.default
        var result: [(url: URL, relativePath: String)] = []
        func visit(_ folder: URL, relative: String) throws {
            for file in try manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys)).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let info = try file.resourceValues(forKeys: keys)
                guard info.isSymbolicLink != true else { throw ExportError.unsafeFile }
                let path = relative.isEmpty ? file.lastPathComponent : relative + "/" + file.lastPathComponent
                if info.isDirectory == true {
                    try visit(file, relative: path)
                } else if file.pathExtension.lowercased() == "json", !file.lastPathComponent.lowercased().hasSuffix(".summary.json") {
                    guard info.isRegularFile == true else { throw ExportError.unsafeFile }
                    result.append((file, path))
                }
            }
        }
        try visit(root, relative: "")
        return result
    }
}

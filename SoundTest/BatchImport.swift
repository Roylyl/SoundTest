import Foundation

/// Keeps selected files on disk, not all decoded PCM in memory. These are temporary
/// copies of explicitly imported files, never automatic microphone recordings.
struct BatchAudioFile: Identifiable, Sendable {
    let id: String
    let filename: String
    let localURL: URL?
    let importError: String?
}

struct BatchImportSelection: Sendable {
    let directory: URL
    let files: [BatchAudioFile]
}

enum BatchImport {
    static let maximumFiles = 100

    static func stage(_ urls: [URL]) throws -> BatchImportSelection {
        guard !urls.isEmpty, urls.count <= maximumFiles else {
            throw SoundError.message("每批请选择 1–\(maximumFiles) 个 WAV 文件。")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SoundTest-Batch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUnlessOpen])
        var files: [BatchAudioFile] = []
        // Use a stable filename order; preserve same-named files from different folders.
        let ordered = urls.enumerated().sorted {
            let order = $0.element.lastPathComponent.localizedStandardCompare($1.element.lastPathComponent)
            return order == .orderedSame ? $0.offset < $1.offset : order == .orderedAscending
        }.map(\.element)
        for url in ordered {
            let id = UUID().uuidString
            let target = directory.appendingPathComponent(id).appendingPathExtension("wav")
            do {
                guard url.pathExtension.lowercased() == "wav" else {
                    throw SoundError.message("批量入口只接受 WAV 文件。")
                }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let coordinator = NSFileCoordinator()
                var coordinationError: NSError?
                var copyError: Error?
                coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { readable in
                    do {
                        let values = try readable.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                        guard values.isRegularFile == true, values.isSymbolicLink != true else {
                            throw SoundError.message("所选项目不是可读取的普通音频文件。")
                        }
                        try FileManager.default.copyItem(at: readable, to: target)
                    } catch { copyError = error }
                }
                if let error = coordinationError ?? (copyError as NSError?) { throw error }
                files.append(BatchAudioFile(id: id, filename: url.lastPathComponent, localURL: target, importError: nil))
            } catch {
                try? FileManager.default.removeItem(at: target)
                files.append(BatchAudioFile(id: id, filename: url.lastPathComponent, localURL: nil, importError: error.localizedDescription))
            }
        }
        return BatchImportSelection(directory: directory, files: files)
    }

    static func remove(_ selection: BatchImportSelection?) {
        guard let selection, selection.directory.lastPathComponent.hasPrefix("SoundTest-Batch-"),
              selection.directory.deletingLastPathComponent().standardizedFileURL == FileManager.default.temporaryDirectory.standardizedFileURL else { return }
        try? FileManager.default.removeItem(at: selection.directory)
    }
}

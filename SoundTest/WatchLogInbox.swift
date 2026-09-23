import Foundation
import WatchConnectivity

// Watch logs are deliberately separate from iPhone Sessions. The schema is
// shared by convention with SoundTestWatch/WatchLog.swift and versioned here.
struct WatchRawScore: Codable, Identifiable {
    let label: String
    let score: Double
    var id: String { label }
}

struct WatchTargetScore: Codable, Identifiable {
    let name: String
    let label: String?
    let score: Double?
    let prompted: Bool
    var id: String { name }
}

struct WatchWindowLog: Codable, Identifiable {
    let index: Int
    let start: Double
    let end: Double
    let scores: [WatchRawScore]
    let targets: [WatchTargetScore]
    var id: Int { index }
}

struct WatchTestLog: Codable, Identifiable {
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
    let inferenceMS: Double?
    let windows: [WatchWindowLog]
}

enum WatchLogStore {
    static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WatchLogs", isDirectory: true)
    }

    static func url(for id: String) -> URL? {
        guard UUID(uuidString: id) != nil else { return nil }
        return directory.appendingPathComponent(id).appendingPathExtension("json")
    }

    static func all() -> [WatchTestLog] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        ) else { return [] }
        return files.compactMap { file in
            let id = file.deletingPathExtension().lastPathComponent
            guard file.pathExtension == "json",
                  let expected = url(for: id), expected.lastPathComponent == file.lastPathComponent,
                  let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  (values.fileSize ?? 0) <= 64_000_000,
                  let data = try? Data(contentsOf: file),
                  let log = try? JSONDecoder().decode(WatchTestLog.self, from: data),
                  log.id == id, log.schemaVersion == 1 else { return nil }
            return log
        }.sorted { $0.startedAt > $1.startedAt }
    }

    @discardableResult
    static func importFile(_ source: URL, expectedID: String?) throws -> String {
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= 64_000_000 else {
            throw NSError(domain: "SoundTestWatchLog", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "手表日志格式或大小无效。"])
        }
        let data = try Data(contentsOf: source)
        let log = try JSONDecoder().decode(WatchTestLog.self, from: data)
        guard log.schemaVersion == 1, UUID(uuidString: log.id) != nil,
              expectedID == nil || expectedID == log.id,
              log.endedAt >= log.startedAt, log.audioSeconds.isFinite, log.audioSeconds >= 0,
              log.threshold.isFinite, (0...1).contains(log.threshold),
              ["appleSoundAnalysisV1", "yamnetCoreML"].contains(log.modelID),
              log.windows.count <= 100_000,
              let destination = url(for: log.id) else {
            throw NSError(domain: "SoundTestWatchLog", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "手表日志标识或字段无效。"])
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            guard try Data(contentsOf: destination) == data else {
                throw NSError(domain: "SoundTestWatchLog", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "同一手表日志标识对应的内容不一致。"])
            }
        } else {
            try data.write(to: destination, options: [.atomic, .completeFileProtectionUnlessOpen])
        }
        return log.id
    }
}

final class WatchLogInbox: NSObject, ObservableObject, WCSessionDelegate {
    @Published private(set) var logs: [WatchTestLog] = WatchLogStore.all()
    @Published private(set) var connectionStatus = "正在检查手表连接"
    @Published private(set) var lastError: String?

    override init() {
        super.init()
        guard WCSession.isSupported() else {
            connectionStatus = "此设备不支持 WatchConnectivity"
            return
        }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    func refresh() { logs = WatchLogStore.all() }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        DispatchQueue.main.async {
            self.connectionStatus = error?.localizedDescription ??
                (activationState == .activated ? (session.isPaired ? "已配对 Apple Watch" : "尚未配对 Apple Watch") : "手表连接尚未激活")
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        guard file.metadata?["soundTestWatchLog"] as? Bool == true else { return }
        let expectedID = file.metadata?["id"] as? String
        do {
            let id = try WatchLogStore.importFile(file.fileURL, expectedID: expectedID)
            DispatchQueue.main.async { self.lastError = nil; self.refresh() }
            // A receipt means the iPhone actually persisted the JSON, not merely
            // that WatchConnectivity queued or transmitted a file.
            session.transferUserInfo(["soundTestWatchLogReceipt": id])
        } catch {
            DispatchQueue.main.async { self.lastError = "手表日志接收失败：\(error.localizedDescription)" }
        }
    }
}

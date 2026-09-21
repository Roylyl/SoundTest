// File identity checks adapted from ASRtest/ModelStore.swift.
import Foundation
import CryptoKit

struct SoundModelStore {
    let root: URL
    let assets: [SoundModelAsset]
    init(root: URL = Bundle.main.resourceURL!) throws {
        self.root = root
        assets = try JSONDecoder().decode([SoundModelAsset].self, from: Data(contentsOf: root.appendingPathComponent("ModelsManifest.json")))
        guard assets.count == SoundModelID.allCases.count, Set(assets.map(\.id)).count == assets.count else {
            throw SoundError.message("内置模型清单不完整。")
        }
    }
    func asset(_ model: SoundModelID) throws -> SoundModelAsset {
        guard let asset = assets.first(where: { $0.id == model.rawValue }) else { throw SoundError.message("找不到模型清单。") }
        return asset
    }
    func folder(_ model: SoundModelID) -> URL { root.appendingPathComponent("ModelLibrary/\(model.rawValue)", isDirectory: true) }
    func available(_ model: SoundModelID) -> Bool {
        guard let asset = try? asset(model) else { return false }
        return asset.files.allSatisfy { file in
            guard let url = try? safeFile(file.path, under: folder(model)),
                  let values = try? url.resourceValues(forKeys: [.fileSizeKey]) else { return false }
            return Int64(values.fileSize ?? -1) == file.bytes
        }
    }
    func validate(_ model: SoundModelID) throws -> SoundModelAsset {
        let asset = try asset(model)
        guard !asset.files.isEmpty, Set(asset.files.map(\.path)).count == asset.files.count,
              asset.files.contains(where: { $0.path == asset.modelFile }),
              asset.files.contains(where: { $0.path == asset.labelsFile }) else { throw SoundError.message("模型文件清单无效。") }
        for file in asset.files {
            let url = try safeFile(file.path, under: folder(model))
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            guard Int64(values.fileSize ?? -1) == file.bytes, try Self.sha256(url) == file.sha256.lowercased() else {
                throw SoundError.message("\(model.title)：\(file.path) 大小或 SHA256 校验失败。")
            }
        }
        return asset
    }
    private func safeFile(_ path: String, under root: URL) throws -> URL {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") }) else { throw SoundError.message("无效资源路径。") }
        var url = root
        for component in components {
            url.appendPathComponent(String(component))
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw SoundError.message("模型文件不允许符号链接。") }
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else { throw SoundError.message("模型文件不是普通文件。") }
        return url
    }
    static func sha256(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var digest = SHA256()
        while let data = try file.read(upToCount: 1_048_576), !data.isEmpty { digest.update(data: data) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

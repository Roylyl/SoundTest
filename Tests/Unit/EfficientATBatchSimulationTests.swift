import Foundation
import XCTest
@testable import SoundTest

/// Runs the five fixed FSD50K groups through the App's real batch controller on
/// an isolated iOS simulator. Each Session JSON is persisted by SoundController.
/// This measures simulator integration, not iPhone power or on-device latency.
final class EfficientATBatchSimulationTests: XCTestCase {
    private struct Group {
        let directory: String
        let prefix: String
        let label: String
    }

    private let groups = [
        Group(directory: "猫叫_100条", prefix: "S01_cat_", label: "猫叫"),
        Group(directory: "狗叫_100条", prefix: "S01_dog_", label: "狗叫"),
        Group(directory: "咳嗽_100条", prefix: "S02_cough_", label: "咳嗽"),
        Group(directory: "笑声_100条", prefix: "S03_laugh_", label: "笑声"),
        Group(directory: "鼓掌_100条", prefix: "S04_clap_", label: "鼓掌")
    ]

    /// Xcode's synchronized Tests/Unit group can preserve the copied fixture
    /// directory, or flatten resources into the .xctest root. Accept either.
    private func files(for group: Group) throws -> [URL] {
        let bundle = Bundle(for: EfficientATBatchSimulationTests.self)
        let root = try XCTUnwrap(bundle.resourceURL)
        let manager = FileManager.default
        let candidates = [
            root.appendingPathComponent("Fixtures/EfficientATBatch500/\(group.directory)", isDirectory: true),
            root.appendingPathComponent("EfficientATBatch500/\(group.directory)", isDirectory: true),
            root.appendingPathComponent(group.directory, isDirectory: true),
            root
        ]
        for directory in candidates where manager.fileExists(atPath: directory.path) {
            let files = try manager.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles])
                .filter { $0.pathExtension.lowercased() == "wav" && $0.lastPathComponent.hasPrefix(group.prefix) }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            if !files.isEmpty {
                XCTAssertEqual(files.count, 100, "Fixture group is incomplete: \(group.directory)")
                XCTAssertEqual(Set(files.map(\.lastPathComponent)).count, 100)
                for file in files {
                    let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    XCTAssertEqual(values.isRegularFile, true)
                    XCTAssertNotEqual(values.isSymbolicLink, true)
                }
                return files
            }
        }
        throw SoundError.message("500 WAV fixtures were not packaged into the test bundle: \(group.directory)")
    }

    @MainActor private func waitUntil(_ description: String, timeout: TimeInterval,
                                       _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard condition() else { throw SoundError.message("Timed out waiting for \(description)") }
    }

    @MainActor func testFiveHundredWAVsWithEfficientATMN10() async throws {
        // The licensed 500-WAV set is kept beside the exported results, not in
        // this source project. Normal unit-test runs may omit the optional set.
        let fixtureGroups: [(Group, [URL])]
        do {
            fixtureGroups = try groups.map { ($0, try files(for: $0)) }
        } catch {
            throw XCTSkip("Optional EfficientAT 500-WAV fixtures are absent: \(error.localizedDescription)")
        }
        XCTAssertEqual(fixtureGroups.reduce(0) { $0 + $1.1.count }, 500)
        // Run on a fresh, dedicated simulator. Never erase existing test logs.
        XCTAssertTrue(SoundSessionStore.all().isEmpty, "Use a fresh simulator so old Sessions do not contaminate this run.")
        XCTAssertTrue(BatchLogStore.all().isEmpty, "Use a fresh simulator so old BatchGroups do not contaminate this run.")
        guard SoundSessionStore.all().isEmpty && BatchLogStore.all().isEmpty else { return }

        // Change this raw value only if the integrated SoundModelID uses another name.
        let model = try XCTUnwrap(SoundModelID(rawValue: "efficientAT"))
        XCTAssertEqual(model.sampleRate, 32_000)
        let app = SoundController(loadInitialModel: false)
        app.selectModel(model)
        try await waitUntil("EfficientAT model load", timeout: 180) {
            app.ready || app.errorMessage != nil
        }
        XCTAssertTrue(app.ready, app.errorMessage ?? app.status)
        guard app.ready else { return }

        app.options.mode = .segment
        app.options.windowSeconds = 10
        app.options.stepSeconds = 2
        app.options.mergeGapSeconds = 0
        app.options.threads = 2
        for target in TargetCategory.all { app.options.thresholds[target.id] = 0.30 }
        app.applySettings()
        try await waitUntil("EfficientAT settings", timeout: 180) {
            app.ready && app.canConfigure
        }

        var completedGroups: [BatchLogGroup] = []
        var allRecordIDs = Set<String>()
        for (group, urls) in fixtureGroups {
            let inputByName = Dictionary(uniqueKeysWithValues: urls.map { ($0.lastPathComponent, $0) })
            app.importBatch(urls)
            try await waitUntil("\(group.label) fixture staging", timeout: 180) {
                !app.preparing && app.batchFiles.count == 100
            }
            XCTAssertEqual(Set(app.batchFiles.map(\.filename)), Set(inputByName.keys))
            app.batchName = "EfficientAT mn10 · \(group.label) · 100 WAV"
            app.analyzeBatch()
            try await waitUntil("\(group.label) batch analysis", timeout: 1_800) {
                !app.batchActive && !app.busy && !app.preparing && app.activeBatchGroup?.endedAt != nil
            }
            let published = try XCTUnwrap(app.activeBatchGroup)
            let saved = try BatchLogStore.load(published.id)
            XCTAssertEqual(saved.status, .completed)
            XCTAssertEqual(saved.model, model)
            XCTAssertEqual(saved.items.count, 100)
            XCTAssertEqual(saved.completedCount, 100, "\(group.label): \(saved.summary)")
            XCTAssertEqual(saved.failedCount, 0)
            for item in saved.items {
                XCTAssertEqual(item.status, .completed, "\(item.filename): \(item.error ?? "unknown error")")
                let id = try XCTUnwrap(item.recordID)
                XCTAssertTrue(allRecordIDs.insert(id).inserted)
                let record = try SoundSessionStore.load(id)
                XCTAssertEqual(record.model, model)
                XCTAssertEqual(record.batch?.groupID, saved.id)
                XCTAssertEqual(record.material.filename, item.filename)
                XCTAssertEqual(record.material.originalSampleRate, 16_000)
                XCTAssertEqual(record.modelSampleRate, 32_000)
                XCTAssertEqual(record.material.sha256, try SoundModelStore.sha256(XCTUnwrap(inputByName[item.filename])))
                XCTAssertNil(record.error)
                XCTAssertFalse(record.windows.isEmpty)
                XCTAssertTrue(record.windows.allSatisfy { $0.scores.count == model.expectedCount })
            }
            completedGroups.append(saved)
            app.clearBatch()
            print("MN10_BATCH_DONE \(group.label) sessions=\(saved.completedCount) groupID=\(saved.id)")
        }

        XCTAssertEqual(completedGroups.count, 5)
        XCTAssertEqual(allRecordIDs.count, 500)
        XCTAssertEqual(SoundSessionStore.all().filter { $0.model == model }.count, 500)
        XCTAssertEqual(BatchLogStore.all().filter { $0.model == model }.count, 5)

        // The same application export path used by the UI creates a snapshot ZIP.
        let archive = try AllLogsExport.create()
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))
        print("MN10_ALL_LOGS_ZIP=\(archive.path)")
    }
}

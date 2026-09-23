import XCTest
import zlib
@testable import SoundTest

final class LogExportTests: XCTestCase {
    private var fixtures: URL!
    private var sessions: URL { fixtures.appendingPathComponent("Sessions", isDirectory: true) }
    private var exports: URL { fixtures.appendingPathComponent("Exports", isDirectory: true) }

    override func setUpWithError() throws {
        fixtures = FileManager.default.temporaryDirectory.appendingPathComponent("LogExportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: fixtures) }

    @discardableResult private func put(_ path: String, _ text: String) throws -> Data {
        let file = sessions.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = Data(text.utf8)
        try data.write(to: file)
        return data
    }

    func testExportsCompleteRecordsAndGroupsWithoutSummaryAudioOrModelFiles() throws {
        let singleID = UUID().uuidString, groupedID = UUID().uuidString, groupID = UUID().uuidString
        let single = try put("\(singleID).json", "{\"id\":\"\(singleID)\",\"windows\":[{\"scores\":[0.125,0.875]}],\"events\":[{\"name\":\"咳嗽\"}]}")
        let grouped = try put("\(groupedID).json", "{\"id\":\"\(groupedID)\",\"batch\":{\"groupID\":\"\(groupID)\"},\"windows\":[{\"scores\":[0.25,0.75]}]}")
        let group = try put("BatchGroups/\(groupID).json", "{\"id\":\"\(groupID)\",\"items\":[{\"recordID\":\"\(groupedID)\"}]}")
        let cache = try put("\(singleID).summary.json", "{\"windows\":[],\"events\":[]}")
        let audio = try put("unused.wav", "not an exported recording")
        let model = try put("unused.onnx", "not an exported model")

        let output = try AllLogsExport.create(sessionsDirectory: sessions, exportDirectory: exports)
        defer { AllLogsExport.cleanup(output) }
        let attachment = XCTAttachment(contentsOfFile: output)
        attachment.name = "SoundTest-all-logs-valid-archive"
        attachment.lifetime = .keepAlways
        add(attachment)
        let entries = try unzipForTest(output)
        let root = "SoundTest-Logs/Sessions/"
        XCTAssertEqual(entries[root + "\(singleID).json"], single)
        XCTAssertEqual(entries[root + "\(groupedID).json"], grouped)
        XCTAssertEqual(entries[root + "BatchGroups/\(groupID).json"], group)
        XCTAssertEqual(entries.keys.filter { $0.hasSuffix(".json") }.count, 3)
        XCTAssertNotNil(entries["SoundTest-Logs/README.txt"])
        XCTAssertFalse(entries.keys.contains { $0.hasSuffix(".summary.json") || $0.hasSuffix(".wav") || $0.hasSuffix(".onnx") })
        for (name, expected) in [("\(singleID).json", single), ("\(groupedID).json", grouped), ("BatchGroups/\(groupID).json", group), ("\(singleID).summary.json", cache), ("unused.wav", audio), ("unused.onnx", model)] {
            XCTAssertEqual(try Data(contentsOf: sessions.appendingPathComponent(name)), expected, "Source file changed: \(name)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.deletingLastPathComponent().appendingPathComponent("SoundTest-Logs").path), "The uncompressed snapshot should not remain after export")
    }

    func testUnknownDamagedAndUncachedJSONArePreservedExactly() throws {
        let damaged = try put("broken.json", "{broken:内容 without valid JSON")
        let uncached = try put("older-no-summary.json", "{\"schemaVersion\":999,\"windows\":[\"\(String(repeating: "full-scores-", count: 100_000))\"]}")
        let damagedGroup = try put("BatchGroups/damaged-group.json", "not valid JSON either")
        let output = try AllLogsExport.create(sessionsDirectory: sessions, exportDirectory: exports)
        defer { AllLogsExport.cleanup(output) }
        let entries = try unzipForTest(output)
        XCTAssertEqual(entries["SoundTest-Logs/Sessions/broken.json"], damaged)
        XCTAssertEqual(entries["SoundTest-Logs/Sessions/older-no-summary.json"], uncached)
        XCTAssertEqual(entries["SoundTest-Logs/Sessions/BatchGroups/damaged-group.json"], damagedGroup)
    }

    func testEmptyMissingAndSummaryOnlyStoresReportNoLogsWithoutCreatingExport() throws {
        XCTAssertThrowsError(try AllLogsExport.create(sessionsDirectory: sessions, exportDirectory: exports))
        XCTAssertThrowsError(try AllLogsExport.create(sessionsDirectory: fixtures.appendingPathComponent("Missing"), exportDirectory: exports))
        try put("orphan.summary.json", "{}")
        XCTAssertThrowsError(try AllLogsExport.create(sessionsDirectory: sessions, exportDirectory: exports))
        XCTAssertFalse(FileManager.default.fileExists(atPath: exports.path))
    }

    func testRejectsSymbolicLinksWithoutFollowingOrChangingThem() throws {
        let outside = fixtures.appendingPathComponent("outside.json")
        let contents = Data("outside the log store".utf8)
        try contents.write(to: outside)
        try put("normal.json", "{}")
        try FileManager.default.createSymbolicLink(at: sessions.appendingPathComponent("linked.json"), withDestinationURL: outside)
        XCTAssertThrowsError(try AllLogsExport.create(sessionsDirectory: sessions, exportDirectory: exports))
        XCTAssertEqual(try Data(contentsOf: outside), contents)
        XCTAssertFalse(FileManager.default.fileExists(atPath: exports.path))

        let alias = fixtures.appendingPathComponent("LinkedSessions")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: sessions)
        XCTAssertThrowsError(try AllLogsExport.create(sessionsDirectory: alias, exportDirectory: exports))
    }

    func testRepeatedExportsHaveIndependentPathsAndCleanupIsScoped() throws {
        let original = try put("record.json", "{\"value\":1}")
        let first = try AllLogsExport.create(sessionsDirectory: sessions, exportDirectory: exports)
        try put("record.json", "{\"value\":2}")
        let second = try AllLogsExport.create(sessionsDirectory: sessions, exportDirectory: exports)
        defer { AllLogsExport.cleanup(first); AllLogsExport.cleanup(second) }
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try unzipForTest(first)["SoundTest-Logs/Sessions/record.json"], original)
        XCTAssertEqual(try unzipForTest(second)["SoundTest-Logs/Sessions/record.json"], Data("{\"value\":2}".utf8))
        AllLogsExport.cleanup(first)
        AllLogsExport.cleanup(first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.deletingLastPathComponent().path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
        AllLogsExport.cleanup(sessions.appendingPathComponent("record.json"))
        AllLogsExport.cleanup(exports)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessions.appendingPathComponent("record.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }

    func testRejectsExportInsideLogStoreAndUnownedCleanupTargets() throws {
        try put("record.json", "{}")
        XCTAssertThrowsError(try AllLogsExport.create(sessionsDirectory: sessions, exportDirectory: sessions.appendingPathComponent("Exports")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessions.appendingPathComponent("Exports").path))
        let unownedID = UUID().uuidString
        let other = fixtures.appendingPathComponent("SoundTest-Export-\(unownedID)", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let file = other.appendingPathComponent("SoundTest-all-logs-20260922-160000-\(unownedID.prefix(8)).zip")
        try Data("unowned fixture".utf8).write(to: file)
        AllLogsExport.cleanup(file)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    /// Independently reads the small test ZIPs' central directory and verifies
    /// decompression and CRC. Production uses Foundation, never this parser.
    private func unzipForTest(_ url: URL) throws -> [String: Data] {
        let bytes = [UInt8](try Data(contentsOf: url))
        func integer(_ offset: Int, _ count: Int) throws -> Int {
            guard offset >= 0, offset + count <= bytes.count else { throw ZIPTestError.invalid }
            return (0..<count).reduce(0) { $0 | (Int(bytes[offset + $1]) << ($1 * 8)) }
        }
        guard bytes.count >= 22, try integer(0, 4) == 0x04034b50 else { throw ZIPTestError.invalid }
        let end = try XCTUnwrap(stride(from: bytes.count - 22, through: max(0, bytes.count - 65_557), by: -1).first {
            (try? integer($0, 4)) == 0x06054b50
        })
        let count = try integer(end + 10, 2)
        var offset = try integer(end + 16, 4)
        var result: [String: Data] = [:]
        for _ in 0..<count {
            guard try integer(offset, 4) == 0x02014b50 else { throw ZIPTestError.invalid }
            let method = try integer(offset + 10, 2)
            let checksum = try integer(offset + 16, 4)
            let compressedSize = try integer(offset + 20, 4), originalSize = try integer(offset + 24, 4)
            let nameLength = try integer(offset + 28, 2), extraLength = try integer(offset + 30, 2), commentLength = try integer(offset + 32, 2)
            let local = try integer(offset + 42, 4)
            guard offset + 46 + nameLength <= bytes.count else { throw ZIPTestError.invalid }
            let name = String(decoding: bytes[(offset + 46)..<(offset + 46 + nameLength)], as: UTF8.self)
            offset += 46 + nameLength + extraLength + commentLength
            if name.hasSuffix("/") { continue }
            guard try integer(local, 4) == 0x04034b50 else { throw ZIPTestError.invalid }
            let start = try local + 30 + integer(local + 26, 2) + integer(local + 28, 2)
            guard start + compressedSize <= bytes.count else { throw ZIPTestError.invalid }
            let compressed = Array(bytes[start..<(start + compressedSize)])
            let content: [UInt8]
            if method == 0 { content = compressed }
            else if method == 8 {
                var decoded = [UInt8](repeating: 0, count: max(1, originalSize))
                var stream = z_stream()
                guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw ZIPTestError.invalid }
                defer { inflateEnd(&stream) }
                let status = compressed.withUnsafeBytes { source in
                    decoded.withUnsafeMutableBytes { destination in
                        stream.next_in = UnsafeMutablePointer(mutating: source.bindMemory(to: Bytef.self).baseAddress)
                        stream.avail_in = uInt(compressed.count)
                        stream.next_out = destination.bindMemory(to: Bytef.self).baseAddress
                        stream.avail_out = uInt(destination.count)
                        return inflate(&stream, Z_FINISH)
                    }
                }
                guard status == Z_STREAM_END, stream.total_out == originalSize else { throw ZIPTestError.invalid }
                content = Array(decoded.prefix(originalSize))
            } else { throw ZIPTestError.invalid }
            let actualCRC = content.withUnsafeBytes { crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count)) }
            guard content.count == originalSize, actualCRC == checksum else { throw ZIPTestError.invalid }
            result[name] = Data(content)
        }
        return result
    }

    private enum ZIPTestError: Error { case invalid }
}

import XCTest
import AVFoundation
@testable import SoundTest

final class AudioFileTests: XCTestCase {
    private var fixtureDirectory: URL!

    override func setUpWithError() throws {
        fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SoundTest-AudioTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let fixtureDirectory { try FileManager.default.removeItem(at: fixtureDirectory) }
    }

    func testMono16kPreservesAmplitudeDurationAndFinalSamples() throws {
        let frames = 16_003
        let url = try fixture(name: "mono.wav", sampleRate: 16_000, channels: 1, frames: frames) { frame, _ in
            frame == frames - 1 ? 0.75 : Float(sin(Double(frame) * 2 * .pi * 440 / 16_000) * 0.2)
        }
        let value = try AudioFileIO.load(url: url)
        XCTAssertEqual(value.sampleRate, 16_000)
        XCTAssertEqual(value.originalSampleRate, 16_000)
        XCTAssertEqual(value.channels, 1)
        XCTAssertEqual(value.samples.count, frames)
        XCTAssertEqual(value.duration, Double(frames) / 16_000, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(value.samples.last), 0.75, accuracy: 0.00004)
        XCTAssertEqual(value.samples[100], Float(sin(100 * 2 * .pi * 440 / 16_000) * 0.2), accuracy: 0.00004)
    }

    func testStereo48kDownmixIncludesBothChannels() throws {
        let frames = 48_137
        let url = try fixture(name: "stereo.wav", sampleRate: 48_000, channels: 2, frames: frames) { frame, channel in
            let signal = Float(sin(Double(frame) * 2 * .pi * 220 / 48_000) * 0.25)
            return channel == 0 ? signal : -signal
        }
        let value = try AudioFileIO.load(url: url)
        XCTAssertEqual(value.channels, 2)
        XCTAssertEqual(value.originalSampleRate, 48_000)
        XCTAssertEqual(value.samples.count, Int((Double(frames) / 3).rounded()))
        XCTAssertEqual(value.duration, Double(frames) / 48_000, accuracy: 1 / 16_000)
        XCTAssertLessThan(value.samples.map(abs).max() ?? 1, 0.00005,
                          "Opposite signals must cancel; selecting only one channel would leave a tone.")
    }

    func testChunkedResamplingPreservesTheShortFinalChunk() throws {
        for sourceRate in [8_000.0, 16_000.0, 22_050.0, 44_100.0, 48_000.0, 96_000.0] {
            let frames = Int(sourceRate * 1.037) + 19
            let input = (0..<frames).map { Float(sin(Double($0) * 2 * .pi * 220 / sourceRate) * 0.25) }
            let wholeConverter = try MonoAudioResampler(inputRate: sourceRate)
            let whole = try wholeConverter.process(input) + wholeConverter.finish()
            let chunkConverter = try MonoAudioResampler(inputRate: sourceRate)
            var chunks: [Float] = []
            for lower in stride(from: 0, to: frames, by: 137) {
                chunks += try chunkConverter.process(Array(input[lower..<min(frames, lower + 137)]))
            }
            chunks += try chunkConverter.finish()
            XCTAssertEqual(chunks.count, Int((Double(frames) * 16_000 / sourceRate).rounded()), "rate \(sourceRate)")
            XCTAssertEqual(chunks.count, whole.count, "rate \(sourceRate)")
            let maxDifference = zip(chunks, whole).map { abs($0 - $1) }.max() ?? .infinity
            XCTAssertLessThan(maxDifference, 0.00001, "Chunk boundaries changed samples at rate \(sourceRate).")
            XCTAssertGreaterThan(chunks.suffix(100).map(abs).max() ?? 0, 0.1, "The short ending must not disappear.")
            XCTAssertTrue(try chunkConverter.finish().isEmpty, "Finishing twice must not duplicate tail samples.")
        }
    }

    func testEmptyAndMalformedAudioAreRejected() throws {
        let empty = try fixture(name: "empty.wav", sampleRate: 16_000, channels: 1, frames: 0) { _, _ in 0 }
        XCTAssertThrowsError(try AudioFileIO.load(url: empty))
        let malformed = fixtureDirectory.appendingPathComponent("invalid.wav")
        try Data("This is not audio".utf8).write(to: malformed)
        XCTAssertThrowsError(try AudioFileIO.load(url: malformed))
        XCTAssertThrowsError(try AudioFileIO.saveWAV(samples: []))
        XCTAssertThrowsError(try AudioFileIO.saveWAV(samples: [.nan]))
    }

    func testImportLongerThanTenMinutesIsRejected() throws {
        // Low-rate PCM makes the boundary fixture small; the decoder must reject before full resampling.
        let url = try fixture(name: "too-long.wav", sampleRate: 8_000, channels: 1,
                              frames: Int((AudioFileIO.maximumImportSeconds + 0.125) * 8_000)) { _, _ in 0 }
        XCTAssertThrowsError(try AudioFileIO.load(url: url)) { error in
            XCTAssertTrue(error.localizedDescription.contains("10 分钟"), error.localizedDescription)
        }
    }

    func testImportStaysInMemoryAndOnlyExplicitSaveCreatesSample() throws {
        let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                    appropriateFor: nil, create: true)
        let folder = documents.appendingPathComponent("Samples", isDirectory: true)
        let before = sampleFiles(in: folder)
        let input = try fixture(name: "local-source.wav", sampleRate: 16_000, channels: 1, frames: 1_611) { frame, _ in
            Float(sin(Double(frame) * 2 * .pi * 440 / 16_000) * 0.1)
        }
        let decoded = try AudioFileIO.load(url: input)
        XCTAssertEqual(sampleFiles(in: folder), before, "Import must not silently save a recording.")

        let saved = try AudioFileIO.saveWAV(samples: decoded.samples)
        defer { try? FileManager.default.removeItem(at: saved) }
        XCTAssertEqual(saved.deletingLastPathComponent().standardizedFileURL, folder.standardizedFileURL)
        XCTAssertEqual(saved.pathExtension, "wav")
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.path))
        let restored = try AudioFileIO.load(url: saved)
        XCTAssertEqual(restored.samples.count, decoded.samples.count)
        XCTAssertEqual(restored.channels, 1)
        XCTAssertEqual(restored.sampleRate, 16_000)
        XCTAssertLessThan(zip(restored.samples, decoded.samples).map { abs($0 - $1) }.max() ?? 1, 0.00005)
    }

    private func sampleFiles(in folder: URL) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
    }

    private func fixture(name: String, sampleRate: Double, channels: Int, frames: Int,
                         value: (Int, Int) -> Float) throws -> URL {
        let url = fixtureDirectory.appendingPathComponent(name)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192))
        let data = try XCTUnwrap(buffer.floatChannelData)
        var position = 0
        while position < frames {
            let count = min(Int(buffer.frameCapacity), frames - position)
            buffer.frameLength = AVAudioFrameCount(count)
            for channel in 0..<channels {
                for frame in 0..<count { data[channel][frame] = value(position + frame, channel) }
            }
            try file.write(from: buffer)
            position += count
        }
        return url
    }
}

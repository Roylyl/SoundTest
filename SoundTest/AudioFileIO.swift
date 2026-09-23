import Foundation
import AVFoundation

enum SoundAudioError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

struct DecodedAudio: Sendable {
    let samples: [Float]
    let sampleRate: Double
    let originalSampleRate: Double
    let channels: Int
    let filename: String
    var duration: Double { Double(samples.count) / sampleRate }
}

/// Files are decoded locally. Filenames and test annotations never enter the audio pipeline.
enum AudioFileIO {
    static let sampleRate = 16_000.0
    static let maximumImportSeconds = 600.0

    static func load(url: URL, sampleRate: Double = sampleRate) throws -> DecodedAudio {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        guard format.sampleRate > 0, format.channelCount > 0,
              file.length > 0 else { throw SoundAudioError.message("音频为空或采样格式不可用。") }
        guard Double(file.length) / format.sampleRate <= maximumImportSeconds else {
            throw SoundAudioError.message("单次导入上限为 10 分钟，请先截取需要对比的音频片段。")
        }
        let resampler = try MonoAudioResampler(inputRate: format.sampleRate, outputRate: sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else {
            throw SoundAudioError.message("无法分配音频解码缓冲区。")
        }
        let limit = Int(maximumImportSeconds * sampleRate)
        var samples: [Float] = []
        samples.reserveCapacity(min(limit, Int(Double(file.length) * sampleRate / format.sampleRate) + 1024))
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: buffer.frameCapacity)
            guard buffer.frameLength > 0 else { break }
            samples.append(contentsOf: try resampler.process(Self.downmix(buffer)))
            guard samples.count <= limit else {
                throw SoundAudioError.message("解码后的音频超过 10 分钟导入上限。")
            }
        }
        samples.append(contentsOf: try resampler.finish())
        guard !samples.isEmpty else { throw SoundAudioError.message("未从文件中解码到有效音频。") }
        guard samples.count <= limit + 1 else { throw SoundAudioError.message("音频超过 10 分钟导入上限。") }
        guard samples.allSatisfy(\.isFinite) else { throw SoundAudioError.message("音频包含无效的采样值。") }
        return DecodedAudio(samples: samples, sampleRate: sampleRate,
                            originalSampleRate: format.sampleRate, channels: Int(format.channelCount),
                            filename: url.lastPathComponent)
    }

    /// Arithmetic mean of every channel; no speech VAD, loudness normalization, or filename conditioning.
    static func downmix(_ buffer: AVAudioPCMBuffer) throws -> [Float] {
        guard buffer.format.commonFormat == .pcmFormatFloat32,
              !buffer.format.isInterleaved, let data = buffer.floatChannelData else {
            throw SoundAudioError.message("只接受已解码的非交错 Float32 PCM 音频。")
        }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard channels > 0 else { throw SoundAudioError.message("音频没有可用通道。") }
        var mono = [Float](repeating: 0, count: frames)
        let scale = 1 / Float(channels)
        for channel in 0..<channels {
            for frame in 0..<frames { mono[frame] += data[channel][frame] * scale }
        }
        return mono
    }

    /// Called only when the user chooses to retain a local test sample. Capture itself never writes audio.
    static func saveWAV(samples: [Float], sampleRate: Double = sampleRate) throws -> URL {
        guard !samples.isEmpty, samples.allSatisfy(\.isFinite), sampleRate > 0 else {
            throw SoundAudioError.message("没有可保存的有效音频。")
        }
        let folder = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
            .appendingPathComponent("Samples", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.complete])
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let url = folder.appendingPathComponent("SoundTest-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(8)).wav")
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
        do {
            // AVAudioFile converts the float input to ordinary mono signed 16-bit WAV.
            let file = try AVAudioFile(forWriting: url, settings: settings,
                                      commonFormat: .pcmFormatFloat32, interleaved: false)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192),
                  let data = buffer.floatChannelData else { throw SoundAudioError.message("无法创建 WAV 缓冲区。") }
            var position = 0
            while position < samples.count {
                let count = min(Int(buffer.frameCapacity), samples.count - position)
                buffer.frameLength = AVAudioFrameCount(count)
                for frame in 0..<count { data[0][frame] = max(-1, min(1, samples[position + frame])) }
                try file.write(from: buffer)
                position += count
            }
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
            return url
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
}

/// Stateful sample-rate conversion shared by microphone capture and file import.
/// Reusing one converter across buffers prevents a new resampling boundary in every microphone callback.
final class MonoAudioResampler {
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter?
    private var finished = false
    private var inputFrames = 0
    private var deliveredFrames = 0
    private var pendingOutput: [Float] = []

    init(inputRate: Double, outputRate: Double = 16_000) throws {
        guard inputRate > 0, outputRate > 0,
              let input = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputRate, channels: 1, interleaved: false),
              let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: outputRate, channels: 1, interleaved: false) else {
            throw SoundAudioError.message("无法创建采样率转换格式。")
        }
        inputFormat = input; outputFormat = output
        if inputRate == outputRate { converter = nil }
        else {
            guard let value = AVAudioConverter(from: input, to: output) else {
                throw SoundAudioError.message("无法将输入音频转换为目标采样率单声道。")
            }
            value.primeMethod = .none
            converter = value
        }
    }

    func process(_ samples: [Float]) throws -> [Float] {
        guard !finished else { throw SoundAudioError.message("采样率转换已结束。") }
        guard !samples.isEmpty else { return [] }
        guard let converter else { return samples }
        inputFrames += samples.count
        guard let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let data = input.floatChannelData else { throw SoundAudioError.message("无法分配采样率转换缓冲区。") }
        input.frameLength = input.frameCapacity
        samples.withUnsafeBufferPointer { data[0].update(from: $0.baseAddress!, count: samples.count) }
        return bounded(try convert(converter, input: input, end: false), final: false)
    }

    func finish() throws -> [Float] {
        guard !finished else { return [] }
        finished = true
        guard let converter else { return [] }
        return bounded(try convert(converter, input: nil, end: true), final: true)
    }

    /// AVAudioConverter may emit filter-tail padding. Hold fractional-frame excess across chunks,
    /// then omit the final padding so recorded duration and event offsets match actual input time.
    private func bounded(_ output: [Float], final: Bool) -> [Float] {
        pendingOutput.append(contentsOf: output)
        let target = Int((Double(inputFrames) * outputFormat.sampleRate / inputFormat.sampleRate).rounded())
        let count = min(pendingOutput.count, max(0, target - deliveredFrames))
        let result = Array(pendingOutput.prefix(count))
        pendingOutput.removeFirst(count)
        deliveredFrames += count
        if final { pendingOutput.removeAll() }
        return result
    }

    private func convert(_ converter: AVAudioConverter, input: AVAudioPCMBuffer?, end: Bool) throws -> [Float] {
        let expected = input.map { Int(ceil(Double($0.frameLength) * outputFormat.sampleRate / inputFormat.sampleRate)) } ?? 0
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(max(4096, expected + 256))) else {
            throw SoundAudioError.message("无法分配转换后的音频缓冲区。")
        }
        var supplied = false
        var result: [Float] = []
        while true {
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                if !supplied, let input {
                    supplied = true; inputStatus.pointee = .haveData; return input
                }
                inputStatus.pointee = end ? .endOfStream : .noDataNow
                return nil
            }
            if let error { throw error }
            if let data = output.floatChannelData, output.frameLength > 0 {
                result.append(contentsOf: UnsafeBufferPointer(start: data[0], count: Int(output.frameLength)))
            }
            switch status {
            case .haveData: continue
            case .inputRanDry, .endOfStream: return result
            case .error: throw SoundAudioError.message("采样率转换失败。")
            @unknown default: throw SoundAudioError.message("采样率转换返回未知状态。")
            }
        }
    }
}

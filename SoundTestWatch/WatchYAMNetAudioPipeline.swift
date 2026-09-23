import AVFoundation
import Foundation

/// Captures Watch microphone audio and runs every complete YAMNet patch on the Watch.
/// Neither samples nor inference requests leave the device. The audio tap only copies
/// buffers; resampling and Core ML prediction run on one serial background queue.
final class WatchYAMNetAudioPipeline {
    private let audioEngine = AVAudioEngine()
    private let analysisQueue = DispatchQueue(label: "SoundTestWatch.YAMNetAudio", qos: .userInitiated)
    private let stateLock = NSLock()
    private let model: WatchYAMNetEngine
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let hardwareRate: Double
    private let threshold: Double
    private let onWindow: (WatchWindowLog) -> Void
    private let onError: (String) -> Void

    let inputName: String

    // Protected by stateLock because the tap and UI can call these concurrently.
    private var accepting = true
    private var pendingFrames = 0
    private var failed = false
    private var inferenceMilliseconds = 0.0

    // The following state belongs exclusively to analysisQueue.
    private var inputFrames = 0
    private var deliveredFrames = 0
    private var pendingConverted: [Float] = []
    private var samples: [Float] = []
    private var windowStartSample = 0
    private var nextWindowIndex = 0

    var inferenceMS: Double {
        stateLock.lock()
        defer { stateLock.unlock() }
        return inferenceMilliseconds
    }

    init(threshold: Double,
         onWindow: @escaping (WatchWindowLog) -> Void,
         onError: @escaping (String) -> Void) throws {
        guard threshold.isFinite, (0...1).contains(threshold) else {
            throw PipelineError.invalidThreshold
        }
        self.threshold = threshold
        self.onWindow = onWindow
        self.onError = onError
        model = try WatchYAMNetEngine()

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default)
        try session.setActive(true)
        do {
            let input = audioEngine.inputNode
            let inputFormat = input.outputFormat(forBus: 0)
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
                  let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: Double(YAMNetWatchFeatures.sampleRate),
                                             channels: 1, interleaved: false),
                  let audioConverter = AVAudioConverter(from: inputFormat, to: format) else {
                throw PipelineError.unsupportedMicrophoneFormat
            }
            audioConverter.primeMethod = .none
            outputFormat = format
            converter = audioConverter
            hardwareRate = inputFormat.sampleRate
            inputName = session.currentRoute.inputs.first?.portName ?? "Apple Watch 麦克风"

            input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
                self?.acceptTap(buffer)
            }
            do {
                audioEngine.prepare()
                try audioEngine.start()
            } catch {
                input.removeTap(onBus: 0)
                throw error
            }
        } catch {
            try? session.setActive(false)
            throw error
        }
    }

    /// Close the tap before the queue barrier. No model call starts after completion.
    /// A short final patch is not classified because zero-padding would make it a
    /// different 0.975-second input; the recorded duration still reflects all audio.
    func stop(completion: @escaping (Double) -> Void) {
        stateLock.lock()
        let wasAccepting = accepting
        accepting = false
        stateLock.unlock()
        guard wasAccepting || audioEngine.isRunning else {
            analysisQueue.async { [self] in
                DispatchQueue.main.async { completion(Double(self.inputFrames) / self.hardwareRate) }
            }
            return
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        analysisQueue.async { [self] in
            // Flush the converter only to account for the real captured frame count.
            // The final incomplete patch is intentionally left unclassified.
            do {
                let tail = try convert(nil, end: true)
                try appendConverted(tail)
            } catch {
                reportFailure("停止录音时处理音频失败：\(error.localizedDescription)")
            }
            let duration = Double(inputFrames) / hardwareRate
            try? AVAudioSession.sharedInstance().setActive(false)
            DispatchQueue.main.async { completion(duration) }
        }
    }

    private func acceptTap(_ source: AVAudioPCMBuffer) {
        let frameCount = Int(source.frameLength)
        guard frameCount > 0 else { return }
        stateLock.lock()
        // A slow model must stop visibly rather than silently drop queued audio.
        let exceedsBudget = pendingFrames + frameCount > Int(hardwareRate * 5)
        guard accepting && !exceedsBudget else {
            let shouldReport = accepting && exceedsBudget
            if shouldReport {
                accepting = false
                analysisQueue.async { [self] in
                    reportFailure("手表本地推理积压超过 5 秒，本轮已停止。")
                }
            }
            stateLock.unlock()
            return
        }
        // Keep the lock through copying and queue insertion. Once stop() has
        // disabled acceptance, every previously accepted buffer is already
        // ahead of its finalization block on analysisQueue.
        pendingFrames += frameCount
        guard let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength) else {
            pendingFrames -= frameCount
            accepting = false
            analysisQueue.async { [self] in reportFailure("无法复制麦克风音频缓冲区。") }
            stateLock.unlock()
            return
        }
        copy.frameLength = source.frameLength
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for index in sourceBuffers.indices {
            guard let from = sourceBuffers[index].mData,
                  let to = destinationBuffers[index].mData else {
                pendingFrames -= frameCount
                accepting = false
                analysisQueue.async { [self] in reportFailure("麦克风缓冲区没有 PCM 数据。") }
                stateLock.unlock()
                return
            }
            memcpy(to, from, Int(sourceBuffers[index].mDataByteSize))
            destinationBuffers[index].mDataByteSize = sourceBuffers[index].mDataByteSize
        }
        analysisQueue.async { [self] in
            stateLock.lock(); pendingFrames -= frameCount; let stopped = failed; stateLock.unlock()
            guard !stopped else { return }
            do {
                inputFrames += frameCount
                try appendConverted(convert(copy, end: false))
            } catch {
                reportFailure("手表本地音频分析失败：\(error.localizedDescription)")
            }
        }
        stateLock.unlock()
    }

    private func appendConverted(_ output: [Float]) throws {
        pendingConverted.append(contentsOf: output)
        let expected = Int((Double(inputFrames) * Double(YAMNetWatchFeatures.sampleRate) / hardwareRate).rounded())
        let available = min(pendingConverted.count, max(0, expected - deliveredFrames))
        if available > 0 {
            samples.append(contentsOf: pendingConverted.prefix(available))
            pendingConverted.removeFirst(available)
            deliveredFrames += available
        }
        let patch = YAMNetWatchFeatures.sampleCount
        while samples.count >= patch {
            let waveform = Array(samples.prefix(patch))
            samples.removeFirst(patch)
            let result = try model.classify(samples: waveform, sampleRate: YAMNetWatchFeatures.sampleRate)
            stateLock.lock(); inferenceMilliseconds += result.inferenceMilliseconds; stateLock.unlock()
            let targets = Self.targets(from: result.scores, threshold: threshold)
            let start = Double(windowStartSample) / Double(YAMNetWatchFeatures.sampleRate)
            windowStartSample += patch
            nextWindowIndex += 1
            onWindow(WatchWindowLog(index: nextWindowIndex,
                                    start: start,
                                    end: Double(windowStartSample) / Double(YAMNetWatchFeatures.sampleRate),
                                    scores: result.scores,
                                    targets: targets))
        }
    }

    private func convert(_ input: AVAudioPCMBuffer?, end: Bool) throws -> [Float] {
        let expected = input.map { Int(ceil(Double($0.frameLength) * outputFormat.sampleRate / hardwareRate)) } ?? 0
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat,
                                            frameCapacity: AVAudioFrameCount(max(4096, expected + 256))) else {
            throw PipelineError.conversionFailed
        }
        var supplied = false
        var result: [Float] = []
        for _ in 0..<32 {
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                if !supplied, let input {
                    supplied = true
                    inputStatus.pointee = .haveData
                    return input
                }
                inputStatus.pointee = end ? .endOfStream : .noDataNow
                return nil
            }
            if let error { throw error }
            if let channel = output.floatChannelData, output.frameLength > 0 {
                result.append(contentsOf: UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
            }
            switch status {
            case .haveData: continue
            case .inputRanDry, .endOfStream: return result
            case .error: throw PipelineError.conversionFailed
            @unknown default: throw PipelineError.conversionFailed
            }
        }
        throw PipelineError.conversionFailed
    }

    private func reportFailure(_ text: String) {
        stateLock.lock()
        let shouldReport = !failed
        failed = true
        accepting = false
        stateLock.unlock()
        if shouldReport { onError(text) }
    }

    private static func targets(from scores: [WatchRawScore], threshold: Double) -> [WatchTargetScore] {
        WatchTarget.allCases.map { target in
            let labels: Set<String>
            switch target {
            case .pet:
                labels = ["Bark", "Yip", "Howl", "Bow-wow", "Growling", "Whimper (dog)",
                          "Purr", "Meow", "Hiss", "Caterwaul"]
            case .cough: labels = ["Cough"]
            case .laughter:
                labels = ["Laughter", "Baby laughter", "Giggle", "Snicker", "Belly laugh", "Chuckle, chortle"]
            case .applause: labels = ["Clapping", "Applause"]
            }
            let best = scores.filter { labels.contains($0.label) }.max { $0.score < $1.score }
            return WatchTargetScore(name: target.name,
                                    label: best?.label,
                                    score: best?.score,
                                    prompted: best.map { $0.score >= threshold } ?? false)
        }
    }

    private enum PipelineError: LocalizedError {
        case invalidThreshold, unsupportedMicrophoneFormat, conversionFailed

        var errorDescription: String? {
            switch self {
            case .invalidThreshold: return "识别阈值必须在 0 到 1 之间。"
            case .unsupportedMicrophoneFormat: return "手表麦克风没有可转换的音频格式。"
            case .conversionFailed: return "无法将手表麦克风音频转换为 16 kHz 单声道。"
            }
        }
    }
}

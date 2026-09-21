import Foundation

/// Serial owner of the currently loaded engine. No audio filename or human label is passed to it.
final class AnalysisRunner: @unchecked Sendable {
    let queue = DispatchQueue(label: "SoundTest.inference", qos: .userInitiated)
    var onWindow: ((WindowResult, [EventEstimate]) -> Date?)?
    var onFinished: ((SoundRecord) -> Void)?
    var onFailure: ((String) -> Void)?
    var onDuration: ((Double) -> Void)?
    private var engine: TaggingEngine?
    private var record: SoundRecord?
    private var planner: WindowPlanner?
    private var samples: [Float] = []
    private var baseIndex = 0
    private var totalSamples = 0
    private var live = false
    private var startedUptime = 0.0
    private var previousFinishedUptime = 0.0
    private var firstAudioArrived = false
    private var lastProcessedEnd = 0
    private var capturedForSaving: [Float] = []
    private let lock = NSLock()
    private var pendingSamples = 0
    private var accepting = false
    private var failed = false
    private var cancelReason: String?
    private var savedClip: [Float] = []

    func load(model: SoundModelID, store: SoundModelStore, threads: Int,
              completion: @escaping (Result<(SoundModelAsset, Double), Error>) -> Void) {
        queue.async {
            self.engine = nil
            let start = ProcessInfo.processInfo.systemUptime
            do {
                let asset = try store.validate(model)
                let folder = store.folder(model)
                let modelURL = folder.appendingPathComponent(asset.modelFile)
                let labelsURL = folder.appendingPathComponent(asset.labelsFile)
                if model == .yamnet {
                    self.engine = try YAMNetTagger(modelURL: modelURL, labelsURL: labelsURL, threads: threads)
                } else {
                    self.engine = try SherpaTagger(modelID: model, modelURL: modelURL, labelsURL: labelsURL, threads: threads)
                }
                completion(.success((asset, (ProcessInfo.processInfo.systemUptime - start) * 1000)))
            } catch { completion(.failure(error)) }
        }
    }

    func begin(_ record: SoundRecord, isLive: Bool, completion: @escaping () -> Void) {
        queue.async {
            self.record = record; self.planner = WindowPlanner(options: record.options)
            self.samples = []; self.baseIndex = 0; self.totalSamples = 0; self.lastProcessedEnd = 0
            self.live = isLive; self.startedUptime = ProcessInfo.processInfo.systemUptime
            self.previousFinishedUptime = self.startedUptime
            self.firstAudioArrived = false
            self.capturedForSaving = []; self.savedClip = []
            self.lock.lock(); self.pendingSamples = 0; self.accepting = true; self.failed = false; self.cancelReason = nil; self.lock.unlock()
            completion()
        }
    }

    func push(_ chunk: [Float], rate: Double) {
        guard !chunk.isEmpty else { return }
        let arrivedAt = ProcessInfo.processInfo.systemUptime
        lock.lock()
        guard accepting else { lock.unlock(); return }
        if pendingSamples + chunk.count > 16000 * 30 {
            accepting = false; failed = true; lock.unlock()
            onFailure?("分析积压超过30秒，已停止本轮；没有静默跳窗。请增大步长或选择更轻的模型。")
            return
        }
        pendingSamples += chunk.count; lock.unlock()
        queue.async {
            self.lock.lock(); self.pendingSamples -= chunk.count; self.lock.unlock()
            guard self.record != nil else { return }
            do {
                guard rate == 16000 else { throw SoundError.message("采集输出采样率不匹配：\(rate)。") }
                if !self.firstAudioArrived {
                    self.startedUptime = arrivedAt - Double(chunk.count) / rate
                    self.firstAudioArrived = true
                }
                self.samples.append(contentsOf: chunk); self.totalSamples += chunk.count
                // Explicit saving is offered only for short microphone clips, and audio stays in RAM.
                if self.totalSamples <= 16000 * 60 { self.capturedForSaving.append(contentsOf: chunk) }
                else { self.capturedForSaving.removeAll(keepingCapacity: false) }
                self.onDuration?(Double(self.totalSamples) / 16000)
                if self.record?.options.mode == .continuous && self.record?.error == nil { try self.consume(finishing: false) }
                let limit = self.record?.options.mode == .segment ? 60 : 1800
                if self.totalSamples >= 16000 * limit {
                    self.lock.lock(); self.accepting = false; self.lock.unlock()
                    self.onFailure?("已到本轮\(limit)秒上限，正在保存已采集结果。")
                }
            } catch {
                self.record?.error = error.localizedDescription
                self.lock.lock(); self.accepting = false; self.failed = true; self.lock.unlock()
                self.onFailure?(error.localizedDescription)
            }
        }
    }

    func analyzeFile(_ audio: [Float]) {
        queue.async {
            do {
                self.samples = audio; self.totalSamples = audio.count
                self.onDuration?(Double(audio.count) / 16000)
                try self.consume(finishing: true)
                self.finishOnQueue(reason: nil, stopTime: nil)
            } catch { self.finishOnQueue(reason: error.localizedDescription, stopTime: nil) }
        }
    }

    func finish(reason: String? = nil, stopTime: Double? = nil) {
        lock.lock(); accepting = false; lock.unlock()
        queue.async {
            do {
                if self.record?.error == nil { try self.consume(finishing: true) }
                self.finishOnQueue(reason: reason, stopTime: stopTime)
            } catch { self.finishOnQueue(reason: error.localizedDescription, stopTime: stopTime) }
        }
    }

    func clip(completion: @escaping ([Float]) -> Void) { queue.async { completion(self.savedClip) } }
    func requestCancel(reason: String) { lock.lock(); cancelReason = reason; lock.unlock() }

    private func consume(finishing: Bool) throws {
        guard let engine, var plan = planner else { throw SoundError.message("模型尚未加载。") }
        while let range = plan.next(total: totalSamples, finishing: finishing) {
            lock.lock(); let cancellation = cancelReason; lock.unlock()
            if let cancellation { throw SoundError.message(cancellation) }
            guard let options = record?.options else { return }
            let lower = range.lowerBound - baseIndex, upper = range.upperBound - baseIndex
            guard lower >= 0, upper <= samples.count else { throw SoundError.message("音频窗口丢失，本轮已中止。") }
            var input = Array(samples[lower..<upper])
            let padding = max(0, plan.windowSamples - input.count)
            input.append(contentsOf: repeatElement(0, count: padding))
            let start = ProcessInfo.processInfo.systemUptime
            let endPosition = Double(range.upperBound) / 16000
            let queueDelay = live ? max(0, (start - startedUptime - endPosition) * 1000) : nil
            let scores = try engine.classify(samples: input, sampleRate: 16000)
            let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
            guard !scores.isEmpty, scores.allSatisfy({ $0.score.isFinite }),
                  Set(scores.map(\.index)).count == scores.count else { throw SoundError.message("模型返回了无效类别分数。") }
            var window = WindowResult(index: record!.windows.count, start: Double(range.lowerBound) / 16000,
                end: endPosition, modelInputSeconds: Double(input.count) / 16000,
                paddedSeconds: Double(padding) / 16000, scores: scores,
                targets: EventAnalysis.targets(scores: scores, options: options), inferenceMS: elapsed,
                processingFinishedAt: Date(), windowCollectionSeconds: live ? Double(range.count) / 16000 : nil,
                queueDelayMS: queueDelay, promptAfterWindowMS: live ? max(0, (ProcessInfo.processInfo.systemUptime - startedUptime - endPosition) * 1000) : nil)
            window.additionalAudioWaitMS = live ? max(0, (startedUptime + endPosition - previousFinishedUptime) * 1000) : nil
            EventAnalysis.append(window, to: &record!.events, options: options)
            if let presented = onWindow?(window, record!.events) {
                window.presentedAt = presented
                if let delay = window.promptAfterWindowMS {
                    window.promptAfterWindowMS = delay + max(0, presented.timeIntervalSince(window.processingFinishedAt) * 1000)
                }
            }
            record!.windows.append(window); record!.inferenceMS += elapsed
            previousFinishedUptime = ProcessInfo.processInfo.systemUptime
            lastProcessedEnd = range.upperBound
        }
        planner = plan
        if live && record?.options.mode == .continuous {
            let remove = max(0, min(plan.nextStart - baseIndex, samples.count))
            samples.removeFirst(remove); baseIndex += remove
        }
    }

    func updateInput(_ info: CaptureInfo) {
        queue.async {
            self.startedUptime = info.startedUptime
            if self.record?.windows.isEmpty == true { self.previousFinishedUptime = info.startedUptime }
            self.firstAudioArrived = true
            self.record?.actualInput = info.actualInput
            self.record?.actualInputUID = info.actualInputUID
            self.record?.material.originalSampleRate = info.hardwareSampleRate
            self.record?.material.originalChannels = info.hardwareChannels
        }
    }

    private func finishOnQueue(reason: String?, stopTime: Double?) {
        guard var result = record else { return }
        record = nil
        result.audioSeconds = Double(totalSamples) / 16000
        result.endedAt = Date()
        result.stopWaitMS = stopTime.map { (ProcessInfo.processInfo.systemUptime - $0) * 1000 }
        if let reason { result.error = reason; result.anomalies.append(reason) }
        if result.windows.isEmpty && result.error == nil { result.error = "没有可分析的音频。" }
        lock.lock(); let wasFailed = failed; accepting = false; lock.unlock()
        result.status = result.error == nil && !wasFailed ? "完成" : "中断 / 异常"
        if wasFailed && result.error == nil { result.error = "分析过载或输入异常。" }
        savedClip = live ? capturedForSaving : []
        samples = []; capturedForSaving = []
        onFinished?(result)
    }
}

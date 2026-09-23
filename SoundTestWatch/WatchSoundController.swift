import AVFoundation
import Combine
import Foundation
import SoundAnalysis
import WatchConnectivity
import WatchKit

private final class WatchClassificationObserver: NSObject, SNResultsObserving {
    private let threshold: Double
    private let onWindow: (WatchWindowLog) -> Void
    private let onError: (String) -> Void
    private let lock = NSLock()
    private var nextIndex = 0
    private var terminalResult: Bool?
    private var onTerminal: ((Bool) -> Void)?

    init(threshold: Double, onWindow: @escaping (WatchWindowLog) -> Void,
         onError: @escaping (String) -> Void) {
        self.threshold = threshold
        self.onWindow = onWindow
        self.onError = onError
    }

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult else { return }
        let start = result.timeRange.start.seconds
        let duration = result.timeRange.duration.seconds
        guard start.isFinite, duration.isFinite, start >= 0, duration > 0 else { return }

        let scores = result.classifications.compactMap { item -> WatchRawScore? in
            guard item.confidence.isFinite else { return nil }
            return WatchRawScore(label: item.identifier, score: item.confidence)
        }
        let targets = WatchTarget.allCases.map { target -> WatchTargetScore in
            let best = target.labels.compactMap { label -> WatchRawScore? in
                guard let item = result.classification(forIdentifier: label),
                      item.confidence.isFinite else { return nil }
                return WatchRawScore(label: label, score: item.confidence)
            }.max { $0.score < $1.score }
            return WatchTargetScore(name: target.name, label: best?.label,
                                    score: best?.score, prompted: (best?.score ?? -1) >= threshold)
        }
        lock.lock()
        guard terminalResult == nil else { lock.unlock(); return }
        nextIndex += 1
        // Queue the result before a terminal callback can queue log finalization.
        onWindow(WatchWindowLog(index: nextIndex, start: start, end: start + duration,
                                scores: scores, targets: targets))
        lock.unlock()
    }

    func request(_ request: SNRequest, didFailWithError error: Error) {
        onError(error.localizedDescription)
        finish(completed: true)
    }

    func requestDidComplete(_ request: SNRequest) {
        finish(completed: true)
    }

    func whenTerminal(_ handler: @escaping (Bool) -> Void) {
        lock.lock()
        if let result = terminalResult {
            lock.unlock()
            handler(result)
        } else {
            onTerminal = handler
            lock.unlock()
        }
    }

    func timeoutIfNeeded() {
        finish(completed: false)
    }

    private func finish(completed: Bool) {
        lock.lock()
        guard terminalResult == nil else { lock.unlock(); return }
        terminalResult = completed
        let handler = onTerminal
        onTerminal = nil
        lock.unlock()
        handler?(completed)
    }
}

/// All analyzer work is serialized away from the microphone tap's realtime callback.
private final class WatchAudioPipeline {
    private let engine = AVAudioEngine()
    private let analysisQueue = DispatchQueue(label: "SoundTestWatch.SoundAnalysis", qos: .userInitiated)
    private let tapLock = NSLock()
    private var acceptingTaps = true
    private let analyzer: SNAudioStreamAnalyzer
    private let observer: WatchClassificationObserver
    private let sampleRate: Double
    let inputName: String
    private var analyzedFrames: AVAudioFramePosition = 0 // accessed only on analysisQueue

    init(threshold: Double, onWindow: @escaping (WatchWindowLog) -> Void,
         onError: @escaping (String) -> Void) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default)
        try session.setActive(true)
        var started = false
        defer { if !started { try? session.setActive(false) } }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "SoundTestWatch.Audio", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "手表麦克风未提供可用的 PCM 格式。"])
        }
        sampleRate = format.sampleRate
        inputName = session.currentRoute.inputs.first?.portName ?? "Apple Watch 麦克风"
        analyzer = SNAudioStreamAnalyzer(format: format)
        observer = WatchClassificationObserver(threshold: threshold, onWindow: onWindow, onError: onError)
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        try analyzer.add(request, withObserver: observer)

        // The tap buffer is copied because AVAudioEngine may reuse its storage after the callback.
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.tapLock.lock()
            guard self.acceptingTaps,
                  let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
                self.tapLock.unlock()
                return
            }
            copy.frameLength = buffer.frameLength
            let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
            for index in source.indices {
                guard let src = source[index].mData, let dst = destination[index].mData else { continue }
                memcpy(dst, src, Int(source[index].mDataByteSize))
                destination[index].mDataByteSize = source[index].mDataByteSize
            }
            self.analysisQueue.async {
                self.analyzer.analyze(copy, atAudioFramePosition: self.analyzedFrames)
                self.analyzedFrames += AVAudioFramePosition(copy.frameLength)
            }
            self.tapLock.unlock()
        }
        do {
            engine.prepare()
            try engine.start()
            started = true
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
    }

    func stop(completion: @escaping (Double, String?) -> Void) {
        tapLock.lock()
        acceptingTaps = false
        tapLock.unlock()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        analysisQueue.async { [self] in
            let duration = Double(self.analyzedFrames) / self.sampleRate
            self.observer.whenTerminal { completed in
                DispatchQueue.main.async {
                    completion(duration, completed ? nil : "系统声音分析收尾超时，末尾结果可能缺失。")
                }
            }
            self.analyzer.completeAnalysis()
            self.analysisQueue.asyncAfter(deadline: .now() + 20) { [observer = self.observer] in
                observer.timeoutIfNeeded()
            }
        }
    }
}

private enum ActiveWatchPipeline {
    case soundAnalysis(WatchAudioPipeline)
    case yamnet(WatchYAMNetAudioPipeline)

    var inputName: String {
        switch self {
        case .soundAnalysis(let pipeline): return pipeline.inputName
        case .yamnet(let pipeline): return pipeline.inputName
        }
    }

    var inferenceMS: Double? {
        switch self {
        case .soundAnalysis: return nil
        case .yamnet(let pipeline): return pipeline.inferenceMS
        }
    }

    func stop(completion: @escaping (Double, String?) -> Void) {
        switch self {
        case .soundAnalysis(let pipeline): pipeline.stop(completion: completion)
        case .yamnet(let pipeline): pipeline.stop { completion($0, nil) }
        }
    }
}

@MainActor
final class WatchSoundController: NSObject, ObservableObject {
    @Published private(set) var logs: [WatchTestLog] = []
    @Published private(set) var latestWindow: WatchWindowLog?
    @Published private(set) var isRecording = false
    @Published private(set) var isStarting = false
    @Published private(set) var isStopping = false
    @Published private(set) var elapsedSeconds = 0.0
    @Published private(set) var message: String?
    @Published private(set) var transferMessage = "尚未导出"
    @Published private(set) var transferStatus: [String: String] = [:]
    @Published private(set) var selectedModelID = WatchTestLog.systemModelID
    @Published var threshold: Double {
        didSet { UserDefaults.standard.set(threshold, forKey: "watchThreshold") }
    }
    @Published var hapticsEnabled: Bool {
        didSet { UserDefaults.standard.set(hapticsEnabled, forKey: "watchHapticsEnabled") }
    }

    private var pipeline: ActiveWatchPipeline?
    private var startedAt: Date?
    private var inputName = "Apple Watch 麦克风"
    private var sessionModelID = WatchTestLog.systemModelID
    private var sessionModelName = WatchTestLog.systemModelName
    private var sessionThreshold = 0.30
    private var sessionWindows: [WatchWindowLog] = []
    private var timer: Timer?
    private var active = true
    private var promptedNames: Set<String> = []
    private var queuedIDs: Set<String> = []
    private var awaitingReceiptIDs: Set<String> = []
    private var acknowledgedIDs: Set<String>
    private var pendingStopStatus = "completed"
    private var pendingStopReason: String?
    private var startupError: String?

    var selectedModelName: String {
        WatchModelChoice.all.first { $0.id == selectedModelID }?.name ?? selectedModelID
    }

    var currentInferenceMS: Double? { pipeline?.inferenceMS }

    override init() {
        threshold = UserDefaults.standard.object(forKey: "watchThreshold") as? Double ?? 0.30
        hapticsEnabled = UserDefaults.standard.object(forKey: "watchHapticsEnabled") as? Bool ?? false
        acknowledgedIDs = Set(UserDefaults.standard.stringArray(forKey: "watchAcknowledgedIDs") ?? [])
        super.init()
        logs = WatchLogStore.all()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    func setModel(_ id: String) {
        guard !isRecording && !isStarting && !isStopping,
              let model = WatchModelChoice.all.first(where: { $0.id == id }), model.available else { return }
        selectedModelID = id
        latestWindow = nil
        message = nil
    }

    func setSceneActive(_ value: Bool) {
        active = value
        if !value && isRecording { stop(status: "interrupted", reason: "手表应用离开前台，采集已停止。") }
    }

    func start() {
        guard active && !isRecording && !isStarting && !isStopping else { return }
        guard WatchModelChoice.all.contains(where: { $0.id == selectedModelID && $0.available }) else {
            message = "当前模型尚未接入手表本地推理。"
            return
        }
        isStarting = true
        startupError = nil
        message = nil
        Task { [weak self] in
            let granted = await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
            }
            guard let self else { return }
            guard granted else {
                self.isStarting = false
                self.message = "请在手表设置中允许麦克风访问。"
                return
            }
            guard self.active else { self.isStarting = false; return }
            do {
                self.latestWindow = nil
                self.sessionWindows = []
                self.promptedNames = []
                self.sessionThreshold = self.threshold
                let onWindow: (WatchWindowLog) -> Void = { [weak self] window in
                    DispatchQueue.main.async { self?.accept(window) }
                }
                let onError: (String) -> Void = { [weak self] text in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        if self.isStarting && !self.isRecording {
                            self.startupError = text
                        } else {
                            self.stop(status: "failed", reason: text)
                        }
                    }
                }
                let modelID = self.selectedModelID
                let threshold = self.sessionThreshold
                let pipe = try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<ActiveWatchPipeline, Error>) in
                    DispatchQueue.global(qos: .userInitiated).async {
                        do {
                            let pipeline: ActiveWatchPipeline
                            switch modelID {
                            case WatchTestLog.systemModelID:
                                pipeline = .soundAnalysis(try WatchAudioPipeline(
                                    threshold: threshold, onWindow: onWindow, onError: onError))
                            case WatchYAMNetEngine.modelID:
                                pipeline = .yamnet(try WatchYAMNetAudioPipeline(
                                    threshold: threshold, onWindow: onWindow, onError: onError))
                            default:
                                throw NSError(domain: "SoundTestWatch.Model", code: 1,
                                              userInfo: [NSLocalizedDescriptionKey: "当前模型尚未接入手表本地推理。"])
                            }
                            continuation.resume(returning: pipeline)
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                }
                guard self.active && self.isStarting else {
                    pipe.stop { _, _ in try? AVAudioSession.sharedInstance().setActive(false) }
                    self.isStarting = false
                    return
                }
                self.inputName = pipe.inputName
                self.pipeline = pipe
                self.sessionModelID = modelID
                self.sessionModelName = WatchModelChoice.all.first { $0.id == modelID }?.name ?? modelID
                self.startedAt = Date()
                self.elapsedSeconds = 0
                self.isRecording = true
                self.isStarting = false
                self.timer?.invalidate()
                self.timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    DispatchQueue.main.async {
                        guard let self, let started = self.startedAt else { return }
                        self.elapsedSeconds = Date().timeIntervalSince(started)
                    }
                }
                if let startupError = self.startupError {
                    self.stop(status: "failed", reason: startupError)
                }
                self.startupError = nil
            } catch {
                self.isStarting = false
                self.message = "无法开始本地识别：\(error.localizedDescription)"
            }
        }
    }

    func stop(status: String = "completed", reason: String? = nil) {
        if isStopping {
            if status == "failed" { pendingStopStatus = "failed" }
            appendStopReason(reason)
            return
        }
        guard isRecording, let pipeline, let startedAt else { return }
        pendingStopStatus = status
        pendingStopReason = reason
        isRecording = false
        isStopping = true
        timer?.invalidate()
        timer = nil
        pipeline.stop { [weak self] audioSeconds, stopError in
            guard let self else { return }
            if stopError != nil { self.pendingStopStatus = "failed" }
            self.appendStopReason(stopError)
            self.finish(startedAt: startedAt, audioSeconds: audioSeconds,
                        status: self.pendingStopStatus,
                        reason: self.pendingStopReason,
                        inferenceMS: self.pipeline?.inferenceMS)
        }
    }

    private func appendStopReason(_ reason: String?) {
        guard let reason, !reason.isEmpty else { return }
        if let existing = pendingStopReason, !existing.isEmpty {
            if !existing.contains(reason) { pendingStopReason = existing + "；" + reason }
        } else {
            pendingStopReason = reason
        }
    }

    private func accept(_ window: WatchWindowLog) {
        guard isRecording || isStopping else { return }
        sessionWindows.append(window)
        latestWindow = window
        let current = Set(window.targets.filter(\.prompted).map(\.name))
        if hapticsEnabled && !current.subtracting(promptedNames).isEmpty {
            WKInterfaceDevice.current().play(.notification)
        }
        promptedNames = current
    }

    private func finish(startedAt: Date, audioSeconds: Double, status: String,
                        reason: String?, inferenceMS: Double?) {
        let log = WatchTestLog(
            schemaVersion: WatchTestLog.currentSchemaVersion,
            id: UUID().uuidString,
            startedAt: startedAt,
            endedAt: Date(),
            modelID: sessionModelID,
            modelName: sessionModelName,
            device: WKInterfaceDevice.current().model,
            input: inputName,
            status: status,
            error: reason,
            threshold: sessionThreshold,
            audioSeconds: audioSeconds,
            inferenceMS: inferenceMS,
            windows: sessionWindows
        )
        do {
            try WatchLogStore.save(log)
            logs = WatchLogStore.all()
            message = reason ?? "已保存本次手表本地识别日志。"
        } catch {
            message = "手表日志保存失败：\(error.localizedDescription)"
        }
        try? AVAudioSession.sharedInstance().setActive(false)
        pipeline = nil
        self.startedAt = nil
        sessionWindows = []
        pendingStopReason = nil
        isStopping = false
    }

    func exportAllLogs() {
        logs = WatchLogStore.all()
        guard !logs.isEmpty else { transferMessage = "本机暂无可导出的日志。"; return }
        guard WCSession.isSupported() else { transferMessage = "此设备不支持 Watch Connectivity。"; return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isCompanionAppInstalled else {
            transferMessage = "等待配对 iPhone 安装并启动 SoundTest 后重试。"
            return
        }
        var count = 0
        for log in logs where !queuedIDs.contains(log.id) && !awaitingReceiptIDs.contains(log.id) {
            guard let file = WatchLogStore.fileURL(for: log.id),
                  FileManager.default.fileExists(atPath: file.path) else { continue }
            session.transferFile(file, metadata: [
                "soundTestWatchLog": true,
                "schemaVersion": WatchTestLog.currentSchemaVersion,
                "id": log.id
            ])
            queuedIDs.insert(log.id)
            transferStatus[log.id] = "已排队，等待传送"
            count += 1
        }
        transferMessage = count > 0 ? "已排队 \(count) 份日志；iPhone 入库确认后才显示已接收。" : "日志已在传送队列中。"
    }

    func status(for log: WatchTestLog) -> String {
        if acknowledgedIDs.contains(log.id) { return "iPhone 已接收" }
        return transferStatus[log.id] ?? "仅保存在手表"
    }
}

extension WatchSoundController: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        let text = error?.localizedDescription
        Task { @MainActor [weak self] in
            if let text { self?.transferMessage = "配对通信未激活：\(text)" }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        guard let id = userInfo["soundTestWatchLogReceipt"] as? String,
              UUID(uuidString: id) != nil else { return }
        Task { @MainActor [weak self] in
            guard let self, self.logs.contains(where: { $0.id == id }) else { return }
            self.acknowledgedIDs.insert(id)
            UserDefaults.standard.set(Array(self.acknowledgedIDs), forKey: "watchAcknowledgedIDs")
            self.queuedIDs.remove(id)
            self.awaitingReceiptIDs.remove(id)
            self.transferStatus[id] = "iPhone 已接收"
            self.transferMessage = "iPhone 已确认收到日志。"
        }
    }

    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        guard let id = fileTransfer.file.metadata?["id"] as? String,
              UUID(uuidString: id) != nil else { return }
        let errorText = error?.localizedDescription
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.queuedIDs.remove(id)
            if self.acknowledgedIDs.contains(id) { return }
            if let errorText {
                self.transferStatus[id] = "传送失败：\(errorText)"
                self.transferMessage = "部分日志传送失败，可重新导出。"
            } else {
                self.awaitingReceiptIDs.insert(id)
                self.transferStatus[id] = "文件已传送，等待 iPhone 入库确认"
            }
        }
    }
}

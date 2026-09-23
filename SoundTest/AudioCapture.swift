import Foundation
import AVFoundation
import UIKit

struct AudioInput: Identifiable, Codable, Sendable {
    let id: String
    let name: String
    let portType: String
}

struct CaptureInfo: Sendable {
    let actualInput: String
    let actualInputUID: String
    let hardwareSampleRate: Double
    let hardwareChannels: Int
    let sampleRate: Double
    /// Monotonic capture gate-open time, excluding permission and session setup.
    let startedUptime: Double
}

/// Reuses ASRtest's bounded tap submission and single background audio-session queue.
/// The gate closes before the stop barrier, so callbacks cannot append audio after finalization.
private final class SoundCaptureGate: @unchecked Sendable {
    private let lock = NSLock()
    private var accepting = false
    private var pending = 0
    func open() { lock.lock(); accepting = true; lock.unlock() }
    func close() { lock.lock(); accepting = false; lock.unlock() }
    func submit(_ buffer: AVAudioPCMBuffer, queue: DispatchQueue,
                consume: @escaping @Sendable ([Float]) -> Void,
                fail: @escaping @Sendable (String) -> Void) {
        lock.lock()
        guard accepting else { lock.unlock(); return }
        guard pending < 32 else {
            accepting = false; lock.unlock(); fail("音频采集积压，已停止本轮，避免静默丢失样本。")
            return
        }
        do {
            let mono = try AudioFileIO.downmix(buffer)
            guard !mono.isEmpty else { lock.unlock(); return }
            pending += 1
            queue.async { [self] in
                consume(mono)
                lock.lock(); pending -= 1; lock.unlock()
            }
            lock.unlock()
        } catch {
            accepting = false; lock.unlock(); fail(error.localizedDescription)
        }
    }
}

private final class SoundCaptureTicket: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw SoundAudioError.message("录音准备已取消。") }
    }
    func open(_ gate: SoundCaptureGate) throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw SoundAudioError.message("录音准备已取消。") }
        gate.open()
    }
}

/// Captures all environmental audio; no speech-only VAD and no automatic disk recording.
/// onSamples runs on a serial background queue; the other callbacks and stop completion run on main.
final class AudioCapture: @unchecked Sendable {
    static let shared = AudioCapture()
    private let queue = DispatchQueue(label: "SoundTest.audio-capture", qos: .userInitiated)
    private let lock = NSLock()
    private let gate = SoundCaptureGate()
    private enum State { case idle, preparing, recording, stopping }
    private var state = State.idle
    private var ticket: SoundCaptureTicket?
    private var preferredInputUID: String?
    private var samplesCallback: (@Sendable ([Float], Double) -> Void)?
    private var inputsCallback: (@Sendable ([AudioInput], String) -> Void)?
    private var errorCallback: (@Sendable (String) -> Void)?
    // The following properties are touched only on queue.
    private var engine: AVAudioEngine?
    private var activeTicket: SoundCaptureTicket?
    private var tapInstalled = false
    private var resampler: MonoAudioResampler?
    private var observers: [NSObjectProtocol] = []
    private var refreshWork: DispatchWorkItem?
    private var interrupted = false
    private var lastActualInput = "尚未开始采集"

    var onSamples: (@Sendable ([Float], Double) -> Void)? {
        get { withLock { samplesCallback } }
        set { withLock { samplesCallback = newValue } }
    }
    var onInputs: (@Sendable ([AudioInput], String) -> Void)? {
        get { withLock { inputsCallback } }
        set { withLock { inputsCallback = newValue } }
    }
    var onError: (@Sendable (String) -> Void)? {
        get { withLock { errorCallback } }
        set { withLock { errorCallback = newValue } }
    }

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
                                             object: nil, queue: nil) { [weak self] notification in
            let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            self?.queue.async { [weak self] in
                guard let self else { return }
                self.interrupted = raw == AVAudioSession.InterruptionType.began.rawValue
                if self.interrupted { self.failActive("音频被系统中断，本轮已停止；中断结束后请重新开始。") }
                else { self.scheduleRefresh() }
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification,
                                             object: nil, queue: nil) { [weak self] notification in
            let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            guard raw == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue ||
                    raw == AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue ||
                    raw == AVAudioSession.RouteChangeReason.noSuitableRouteForCategory.rawValue else { return }
            self?.queue.async { [weak self] in
                guard let self else { return }
                self.failActive("麦克风输入设备发生变化，本轮已停止，输入列表已刷新。")
                self.scheduleRefresh()
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                             object: nil, queue: nil) { [weak self] _ in
            self?.queue.async { [weak self] in
                self?.interrupted = false
                self?.failActive("系统音频服务已重置，本轮已停止，请重新开始。")
                self?.scheduleRefresh()
            }
        })
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange,
                                             object: nil, queue: nil) { [weak self] notification in
            guard let changedEngine = notification.object as? AVAudioEngine else { return }
            self?.queue.async { [weak self] in
                guard let self, self.engine === changedEngine,
                      self.withLock({ self.state == .recording }), !changedEngine.isRunning else { return }
                self.failActive("音频引擎配置变化导致采集中断，本轮已停止，请重新开始。")
                self.scheduleRefresh()
            }
        })
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                             object: nil, queue: nil) { [weak self] _ in self?.refreshInputs() })
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                             object: nil, queue: nil) { [weak self] _ in
            self?.queue.async { [weak self] in self?.failActive("App 已进入后台，本轮采集已停止。") }
        })
    }

    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    private var outputSampleRate = 16000.0

    func start(preferredUID: String? = nil, sampleRate: Double = 16000) async throws -> CaptureInfo {
        let current = SoundCaptureTicket()
        let allowed = withLock { () -> Bool in
            guard state == .idle else { return false }
            state = .preparing; ticket = current
            if let preferredUID { preferredInputUID = preferredUID.isEmpty ? nil : preferredUID }
            return true
        }
        guard allowed else { throw SoundAudioError.message("上一轮录音仍在准备、采集或停止中。") }
        let permission = await AVAudioApplication.requestRecordPermission()
        guard permission else {
            withLock { if ticket === current { state = .idle; ticket = nil } }
            throw SoundAudioError.message("未获得麦克风权限，请在系统设置中允许 SoundTest 使用麦克风。")
        }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    try current.check()
                    guard !interrupted else { throw SoundAudioError.message("音频会话仍被系统占用，请稍后重试。") }
                    outputSampleRate = sampleRate
                    activeTicket = current
                    try configureSession()
                    let session = AVAudioSession.sharedInstance()
                    try session.setActive(true)
                    try current.check()
                    let selected = withLock { preferredInputUID }
                    if let selected {
                        guard let input = session.availableInputs?.first(where: { $0.uid == selected }) else {
                            throw SoundAudioError.message("所选麦克风已不可用，请刷新并重新选择。")
                        }
                        try session.setPreferredInput(input)
                        guard session.currentRoute.inputs.contains(where: { $0.uid == selected }) else {
                            throw SoundAudioError.message("系统未切换到所选麦克风，请重新选择后开始。")
                        }
                    } else { try session.setPreferredInput(nil) }
                    let route = session.currentRoute.inputs
                    guard !route.isEmpty else { throw SoundAudioError.message("系统没有可用的音频输入。") }
                    let audio = AVAudioEngine()
                    engine = audio
                    let format = audio.inputNode.outputFormat(forBus: 0)
                    guard format.sampleRate > 0, format.channelCount > 0,
                          format.commonFormat == .pcmFormatFloat32, !format.isInterleaved else {
                        throw SoundAudioError.message("当前麦克风格式不可用，请重新连接设备。")
                    }
                    resampler = try MonoAudioResampler(inputRate: format.sampleRate, outputRate: outputSampleRate)
                    let gate = gate, queue = queue
                    audio.inputNode.installTap(onBus: 0, bufferSize: AVAudioFrameCount(format.sampleRate / 10), format: format) { [weak self] buffer, _ in
                        gate.submit(buffer, queue: queue, consume: { [weak self] mono in
                            guard let self else { return }
                            do {
                                guard let resampler = self.resampler else { return }
                                let values = try resampler.process(mono)
                                if !values.isEmpty { self.onSamples?(values, self.outputSampleRate) }
                            } catch { self.failActive(error.localizedDescription) }
                        }, fail: { [weak self] message in
                            self?.queue.async { [weak self] in self?.failActive(message) }
                        })
                    }
                    tapInstalled = true
                    audio.prepare()
                    try audio.start()
                    let actual = describe(route)
                    let startedUptime = ProcessInfo.processInfo.systemUptime
                    let info = CaptureInfo(actualInput: actual, actualInputUID: route.map(\.uid).joined(separator: ","),
                                           hardwareSampleRate: format.sampleRate, hardwareChannels: Int(format.channelCount),
                                           sampleRate: outputSampleRate, startedUptime: startedUptime)
                    try withLock {
                        try current.open(gate)
                        if ticket === current { state = .recording }
                    }
                    lastActualInput = actual
                    publishInputs(actual: actual)
                    continuation.resume(returning: info)
                } catch {
                    // A permission reply from a cancelled request must not tear down a newer recording.
                    if activeTicket === current { cleanup(flush: false) }
                    withLock { if ticket === current { state = .idle; ticket = nil } }
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop(completion: @escaping @Sendable () -> Void) {
        withLock { ticket?.cancel(); if state != .idle { state = .stopping } }
        gate.close()
        queue.async { [self] in
            cleanup(flush: true)
            withLock { state = .idle; ticket = nil }
            DispatchQueue.main.async(execute: completion)
        }
    }

    func stop() async {
        await withCheckedContinuation { continuation in stop { continuation.resume() } }
    }

    /// An input choice is applied when the next capture starts; active sessions remain attributable to one route.
    func selectInput(uid: String?) {
        let changed = withLock { () -> Bool in
            guard state == .idle else { return false }
            preferredInputUID = uid?.isEmpty == false ? uid : nil
            return true
        }
        if !changed { publishError("请先停止录音，再切换输入源。") }
    }

    /// Called both by the visible refresh button and automatically after route/foreground changes.
    func refreshInputs() { queue.async { [weak self] in self?.scheduleRefresh() } }

    private func configureSession() throws {
        dispatchPrecondition(condition: .onQueue(queue))
        let session = AVAudioSession.sharedInstance()
        // Default mode preserves environmental audio; no voice processing or speech activity gate.
        try session.setCategory(.record, mode: .default, options: [.allowBluetoothHFP])
        try session.setPreferredSampleRate(outputSampleRate)
    }

    private func scheduleRefresh() {
        dispatchPrecondition(condition: .onQueue(queue))
        refreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.performRefresh() }
        refreshWork = work
        queue.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func performRefresh() {
        dispatchPrecondition(condition: .onQueue(queue))
        if withLock({ state != .idle }) { publishInputs(actual: lastActualInput); return }
        guard !interrupted else { return }
        do {
            try configureSession()
            try AVAudioSession.sharedInstance().setActive(true)
            publishInputs(actual: "尚未开始采集")
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            publishError("输入源刷新失败：\(error.localizedDescription)")
        }
    }

    private func publishInputs(actual: String) {
        let values = (AVAudioSession.sharedInstance().availableInputs ?? []).map {
            AudioInput(id: $0.uid, name: $0.portName, portType: $0.portType.rawValue)
        }
        let callback = onInputs
        DispatchQueue.main.async { callback?(values, actual) }
    }

    private func describe(_ route: [AVAudioSessionPortDescription]) -> String {
        route.map { "\($0.portName) · \($0.portType.rawValue)" }.joined(separator: ", ")
    }

    private func failActive(_ message: String) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard withLock({ state == .preparing || state == .recording }) else { return }
        withLock { ticket?.cancel(); state = .stopping }
        gate.close()
        // Defer cleanup behind samples already accepted by the tap submission barrier.
        queue.async { [self] in
            cleanup(flush: true)
            withLock { state = .idle; ticket = nil }
            publishError(message)
        }
    }

    private func cleanup(flush: Bool) {
        dispatchPrecondition(condition: .onQueue(queue))
        gate.close()
        if tapInstalled { engine?.inputNode.removeTap(onBus: 0); tapInstalled = false }
        engine?.stop(); engine = nil
        if flush, let resampler {
            do {
                let remaining = try resampler.finish()
                if !remaining.isEmpty { onSamples?(remaining, outputSampleRate) }
            } catch { publishError("结束音频转换失败：\(error.localizedDescription)") }
        }
        resampler = nil
        activeTicket = nil
        do { try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        catch { publishError("音频会话关闭失败：\(error.localizedDescription)") }
    }

    private func publishError(_ message: String) {
        let callback = onError
        DispatchQueue.main.async { callback?(message) }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }
}

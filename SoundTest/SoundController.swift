import Foundation
import Combine
import UIKit

@MainActor
final class SoundController: ObservableObject {
    @Published var model: SoundModelID = .zipformer
    @Published var options = SoundOptions()
    @Published var material = MaterialInfo()
    @Published var preferredUID = ""
    @Published var inputs: [AudioInput] = []
    @Published var actualInput = "尚未开始采集"
    @Published var status = "准备模型"
    @Published var errorMessage: String?
    @Published var ready = false
    @Published var busy = false
    @Published var recording = false
    @Published var finishing = false
    @Published var preparing = false
    @Published var audioSeconds = 0.0
    @Published var loadMS = 0.0
    @Published var inferenceMS = 0.0
    @Published var currentScores: [RawScore] = []
    @Published var currentTargets: [TargetScore] = []
    @Published var recentWindows: [WindowResult] = []
    @Published var events: [EventEstimate] = []
    @Published var history: [SoundRecord] = []
    @Published var latestRecord: SoundRecord?
    @Published var imported: DecodedAudio?
    @Published var importedHash: String?
    @Published var assets: [SoundModelAsset] = []
    @Published var availableModels: Set<SoundModelID> = []
    @Published var savedSampleURL: URL?
    private var store: SoundModelStore?
    private var asset: SoundModelAsset?
    private let runner = AnalysisRunner()
    private let capture = AudioCapture.shared
    private var runGeneration = 0
    private var pendingStopReason: String?
    private var loadedThreads = 2
    var canConfigure: Bool { !busy && !preparing }
    var top5: [RawScore] { Array(currentScores.sorted { $0.score > $1.score }.prefix(5)) }

    init() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        if let stored = UserDefaults.standard.string(forKey: "SoundTest.model"), let model = SoundModelID(rawValue: stored) { self.model = model }
        restoreOptions()
        capture.onSamples = { [weak runner] samples, rate in runner?.push(samples, rate: rate) }
        capture.onInputs = { [weak self] inputs, actual in
            Task { @MainActor in self?.inputs = inputs; self?.actualInput = actual }
        }
        capture.onError = { [weak self] message in
            Task { @MainActor in self?.handleFailure(message) }
        }
        runner.onDuration = { [weak self] duration in
            DispatchQueue.main.async { self?.audioSeconds = duration }
        }
        runner.onFailure = { [weak self] message in
            DispatchQueue.main.async { self?.handleFailure(message) }
        }
        runner.onWindow = { [weak self] window, events in
            // Runner never executes on main. Timestamp immediately after publishing UI state.
            DispatchQueue.main.sync {
                guard let self else { return nil }
                self.currentScores = window.scores; self.currentTargets = window.targets
                self.inferenceMS += window.inferenceMS; self.events = events
                self.recentWindows.append(window)
                if self.recentWindows.count > 80 { self.recentWindows.removeFirst(self.recentWindows.count - 80) }
                return Date()
            }
        }
        runner.onFinished = { [weak self] record in
            DispatchQueue.main.async { self?.complete(record) }
        }
        do {
            store = try SoundModelStore(); assets = store!.assets
            availableModels = Set(SoundModelID.allCases.filter { store!.available($0) })
        }
        catch { errorMessage = error.localizedDescription; status = "模型清单错误" }
        reloadHistory()
        loadModel()
    }

    func refreshInputs() { capture.refreshInputs() }
    func chooseInput(_ uid: String) { guard canConfigure else { return }; preferredUID = uid; capture.selectInput(uid: uid.isEmpty ? nil : uid) }
    func selectModel(_ next: SoundModelID) {
        guard canConfigure else { return }
        persistOptions(); model = next; restoreOptions()
        UserDefaults.standard.set(model.rawValue, forKey: "SoundTest.model")
        currentScores = []; currentTargets = []; recentWindows = []; events = []
        latestRecord = nil; savedSampleURL = nil; inferenceMS = 0; audioSeconds = 0
        loadModel()
    }
    func restoreDefaults() {
        let mode = options.mode
        options = SoundOptions(); options.mode = mode
        options.windowSeconds = model.defaultWindow; options.stepSeconds = model.defaultStep
        applySettings()
    }
    func applySettings() {
        guard canConfigure else { return }
        do { _ = try options.validated(for: model); persistOptions(); if options.threads != loadedThreads { loadModel() } }
        catch { errorMessage = error.localizedDescription }
    }
    private func persistOptions() {
        if let data = try? JSONEncoder().encode(options) { UserDefaults.standard.set(data, forKey: "SoundTest.options.\(model.rawValue)") }
    }
    private func restoreOptions() {
        options = SoundOptions(); options.windowSeconds = model.defaultWindow; options.stepSeconds = model.defaultStep
        if let data = UserDefaults.standard.data(forKey: "SoundTest.options.\(model.rawValue)"),
           let saved = try? JSONDecoder().decode(SoundOptions.self, from: data),
           (try? saved.validated(for: model)) != nil { options = saved }
    }
    func loadModel() {
        guard !busy, let store else { return }
        ready = false; preparing = true; status = "校验并加载 \(model.title)"
        let loadingModel = model, threads = options.threads
        runner.load(model: loadingModel, store: store, threads: threads) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.preparing = false
                switch result {
                case .success(let value): self.asset = value.0; self.loadMS = value.1; self.ready = true; self.loadedThreads = threads; self.status = "模型就绪 · 完全本地"; self.refreshInputs()
                case .failure(let error): self.asset = nil; self.status = "模型不可用"; self.errorMessage = error.localizedDescription
                }
            }
        }
    }
    private func makeRecord(file: Bool) throws -> SoundRecord {
        guard ready, let asset else { throw SoundError.message("请等待模型加载完成。") }
        _ = try options.validated(for: model)
        guard options.threads == loadedThreads else { throw SoundError.message("线程数已修改，请先应用设置并等待模型重新加载。") }
        var info = material
        if file, let imported {
            info.inputMethod = .file; info.filename = imported.filename; info.sha256 = importedHash
            info.originalSampleRate = imported.originalSampleRate; info.originalChannels = imported.channels
        } else {
            info.filename = nil; info.sha256 = nil; info.savedAudioName = nil
            if info.inputMethod == .file { info.inputMethod = .environment }
        }
        var record = SoundRecord(model: model, asset: asset, options: options,
            device: "\(Self.hardwareModel()) · iOS \(UIDevice.current.systemVersion)",
            actualInput: file ? "本地音频文件（未经过麦克风）" : "等待实际录音路由",
            actualInputUID: file ? "file" : "", material: info)
        record.loadMS = loadMS; record.thermalStart = Self.thermal
        record.batteryStart = UIDevice.current.batteryLevel >= 0 ? UIDevice.current.batteryLevel : nil
        return record
    }
    private func resetForRun() {
        finishing = false
        busy = true; runGeneration += 1; pendingStopReason = nil
        currentScores = []; currentTargets = []; recentWindows = []; events = []
        audioSeconds = 0; inferenceMS = 0; latestRecord = nil; savedSampleURL = nil
    }
    func startRecording() {
        guard ready, canConfigure else { return }
        do {
            let record = try makeRecord(file: false)
            persistOptions(); resetForRun(); preparing = true; status = "准备录音权限与输入"
            let generation = runGeneration, uid = preferredUID
            runner.begin(record, isLive: true) { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    do {
                        guard self.runGeneration == generation, self.busy else { return }
                        let info = try await self.capture.start(preferredUID: uid.isEmpty ? nil : uid)
                        guard self.runGeneration == generation, self.busy else { return }
                        self.runner.updateInput(info)
                        self.actualInput = info.actualInput; self.preparing = false; self.recording = true
                        self.status = self.options.mode == .continuous ? "连续监听中" : "录音中 · 停止后识别"
                    } catch {
                        guard self.runGeneration == generation, self.busy else { return }
                        self.preparing = false
                        self.runner.finish(reason: error.localizedDescription)
                    }
                }
            }
        } catch { errorMessage = error.localizedDescription }
    }
    func stop(reason: String? = nil) {
        guard busy, !finishing else { return }
        finishing = true
        if !recording && !preparing {
            runner.requestCancel(reason: reason ?? "用户停止文件分析。")
            return
        }
        pendingStopReason = reason; runGeneration += 1
        preparing = false; recording = false; status = "处理尾窗并保存日志"
        let time = ProcessInfo.processInfo.systemUptime
        capture.stop { [weak self] in self?.runner.finish(reason: reason, stopTime: time) }
    }
    private func handleFailure(_ message: String) {
        errorMessage = message
        if busy && (recording || preparing) { stop(reason: message) }
    }

    func importAudio(_ url: URL) {
        guard canConfigure else { return }
        preparing = true; status = "读取本地音频"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { () -> (DecodedAudio, String) in
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                return (try AudioFileIO.load(url: url), try SoundModelStore.sha256(url))
            }
            DispatchQueue.main.async {
                guard let self else { return }; self.preparing = false
                switch result {
                case .success(let result): self.imported = result.0; self.importedHash = result.1; self.status = "音频已载入，可切换模型重测"
                case .failure(let error): self.errorMessage = error.localizedDescription; self.status = "音频导入失败"
                }
            }
        }
    }
    func analyzeImported() {
        guard let imported, ready, canConfigure else { return }
        do {
            let record = try makeRecord(file: true)
            persistOptions(); resetForRun(); status = "分析文件 · \(imported.filename)"
            runner.begin(record, isLive: false) { [weak runner] in runner?.analyzeFile(imported.samples) }
        } catch { errorMessage = error.localizedDescription }
    }

    private func complete(_ original: SoundRecord) {
        finishing = true
        var record = original; record.thermalEnd = Self.thermal
        if let reason = pendingStopReason, record.error == nil { record.error = reason; record.status = "中断 / 异常" }
        recording = false; preparing = false
        events = record.events; audioSeconds = record.audioSeconds; inferenceMS = record.inferenceMS
        recentWindows = Array(record.windows.suffix(80))
        if record.options.mode == .segment {
            currentScores = EventAnalysis.average(record.windows)
            currentTargets = EventAnalysis.targets(scores: currentScores, options: record.options)
        }
        latestRecord = record; status = "正在保存测试记录"
        let completed = record
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result { try SoundSessionStore.save(completed) }
            DispatchQueue.main.async {
                guard let self else { return }; self.busy = false
                switch result {
                case .success: self.status = "\(completed.status) · 已保存日志"; self.reloadHistory()
                case .failure(let error): self.status = "日志保存失败"; self.errorMessage = error.localizedDescription
                }
                if let error = completed.error { self.errorMessage = error }
            }
        }
    }
    func saveSample() {
        guard !busy, let record = latestRecord, record.material.inputMethod != .file else { return }
        preparing = true
        runner.clip { [weak self] samples in
            let result = Result { try AudioFileIO.saveWAV(samples: samples) }
            DispatchQueue.main.async {
                guard let self else { return }; self.preparing = false
                switch result {
                case .success(let url):
                    self.savedSampleURL = url
                    var updated = record; updated.material.savedAudioName = url.lastPathComponent
                    self.latestRecord = updated
                    DispatchQueue.global(qos: .utility).async { [weak self] in
                        do { try SoundSessionStore.save(updated); DispatchQueue.main.async { self?.reloadHistory() } }
                        catch { DispatchQueue.main.async { self?.errorMessage = error.localizedDescription } }
                    }
                case .failure(let error): self.errorMessage = error.localizedDescription
                }
            }
        }
    }
    func reloadHistory() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let records = SoundSessionStore.all()
            DispatchQueue.main.async { self?.history = records }
        }
    }
    func delete(_ record: SoundRecord) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            do { try SoundSessionStore.delete(record); DispatchQueue.main.async { self?.reloadHistory() } }
            catch { DispatchQueue.main.async { self?.errorMessage = error.localizedDescription } }
        }
    }
    static var thermal: String {
        switch ProcessInfo.processInfo.thermalState { case .nominal: "正常"; case .fair: "轻度"; case .serious: "严重"; case .critical: "临界"; @unknown default: "未知" }
    }
    static func hardwareModel() -> String {
        var info = utsname(); uname(&info)
        let size = MemoryLayout.size(ofValue: info.machine)
        return withUnsafePointer(to: &info.machine) { $0.withMemoryRebound(to: CChar.self, capacity: size) { String(cString: $0) } }
    }
}

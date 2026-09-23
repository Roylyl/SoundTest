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
    @Published private(set) var historySnapshot = SoundHistorySnapshot()
    @Published private(set) var deletingLogs = false
    @Published private(set) var exportingLogs = false
    var history: [SoundRecord] { historySnapshot.records }
    var batchHistory: [BatchLogGroup] { historySnapshot.groups }
    @Published var latestRecord: SoundRecord?
    @Published var imported: DecodedAudio?
    @Published var importedHash: String?
    @Published var assets: [SoundModelAsset] = []
    @Published var availableModels: Set<SoundModelID> = []
    @Published var savedSampleURL: URL?
    @Published var batchFiles: [BatchAudioFile] = []
    @Published var batchName = ""
    @Published var batchActive = false
    @Published var activeBatchGroup: BatchLogGroup?
    private var batchSelection: BatchImportSelection?
    private var batchTemplate: SoundRecord?
    private var batchIndex = 0
    private var batchStopReason: String?
    private var batchWaitingForRunner = false
    private let historyQueue = DispatchQueue(label: "SoundTest.logs", qos: .utility)
    private var importedScene: DecodedAudio?
    var task: SoundTask { model.task }
    var taskModels: [SoundModelID] { SoundModelID.allCases.filter { $0.task == task } }
    func selectTask(_ task: SoundTask) {
        guard canConfigure, task != self.task else { return }
        selectModel(task == .scenes ? .cpMobile : .zipformer)
        material.testCase = task == .scenes ? "C01" : "S01"
        material.testCaseVersion = task == .scenes ? "soundtest-asc-v1" : "soundtest-s01-s17-v2"
    }
    private var store: SoundModelStore?
    private var asset: SoundModelAsset?
    private let runner = AnalysisRunner()
    private let capture = AudioCapture.shared
    private var runGeneration = 0
    private var pendingStopReason: String?
    private var loadedThreads = 2
    var canConfigure: Bool { !busy && !preparing && !deletingLogs && !exportingLogs }
    var canDeleteLogs: Bool { canConfigure }
    var canExportLogs: Bool { canConfigure }
    var top5: [RawScore] { Array(currentScores.sorted { $0.score > $1.score }.prefix(5)) }

    init(loadInitialModel: Bool = true) {
        UIDevice.current.isBatteryMonitoringEnabled = true
        if let stored = UserDefaults.standard.string(forKey: "SoundTest.model"), let model = SoundModelID(rawValue: stored) { self.model = model }
        restoreOptions()
        if task == .scenes { material.testCase = "C01"; material.testCaseVersion = "soundtest-asc-v1" }
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
        reloadHistory(recoverInterrupted: true)
        if loadInitialModel { loadModel() }
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
        if model.task == .scenes { options.scene = SceneOptions(); options.mode = .continuous }
        applySettings()
    }
    func applySettings() {
        guard canConfigure else { return }
        do { options = try options.validated(for: model); persistOptions(); if options.threads != loadedThreads { loadModel() } }
        catch { errorMessage = error.localizedDescription }
    }
    private func persistOptions() {
        if let data = try? JSONEncoder().encode(options) { UserDefaults.standard.set(data, forKey: "SoundTest.options.\(model.rawValue)") }
    }
    private func restoreOptions() {
        options = SoundOptions(); options.windowSeconds = model.defaultWindow; options.stepSeconds = model.defaultStep
        if model.task == .scenes { options.scene = SceneOptions(); options.mode = .continuous }
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
        options = try options.validated(for: model)
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
        record.taskType = model.task; record.modelSampleRate = model.sampleRate
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
                        let info = try await self.capture.start(preferredUID: uid.isEmpty ? nil : uid, sampleRate: Double(record.model.sampleRate))
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
        if batchActive {
            batchStopReason = reason ?? "用户停止本轮批量测试。"
            finishing = true; status = "正在停止本轮批量测试"
            if batchWaitingForRunner { runner.requestCancel(reason: batchStopReason!) }
            return
        }
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
            let result = Result { () -> (DecodedAudio, String, DecodedAudio) in
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                return (try AudioFileIO.load(url: url), try SoundModelStore.sha256(url), try AudioFileIO.load(url: url, sampleRate: 32000))
            }
            DispatchQueue.main.async {
                guard let self else { return }; self.preparing = false
                switch result {
                case .success(let result): self.imported = result.0; self.importedHash = result.1; self.importedScene = result.2; self.status = "音频已载入，可切换模型重测"
                case .failure(let error): self.errorMessage = error.localizedDescription; self.status = "音频导入失败"
                }
            }
        }
    }
    func analyzeImported() {
        guard let imported, ready, canConfigure else { return }
        guard model.sampleRate != 32000 || importedScene != nil else { errorMessage = "请重新导入原始音频以获得 32 kHz 模型输入。"; return }
        do {
            let record = try makeRecord(file: true)
            persistOptions(); resetForRun(); status = "分析文件 · \(imported.filename)"
            let samples = model.sampleRate == 32000 ? importedScene!.samples : imported.samples
            runner.begin(record, isLive: false) { [weak runner] in runner?.analyzeFile(samples) }
        } catch { errorMessage = error.localizedDescription }
    }

    private func complete(_ original: SoundRecord) {
        if original.batch != nil { completeBatchRecord(original); return }
        finishing = true
        var record = original; record.thermalEnd = Self.thermal
        if let reason = pendingStopReason, record.error == nil { record.error = reason; record.status = "中断 / 异常" }
        recording = false; preparing = false
        events = record.events; audioSeconds = record.audioSeconds; inferenceMS = record.inferenceMS
        recentWindows = Array(record.windows.suffix(80))
        if record.options.mode == .segment && record.model.task == .events {
            currentScores = EventAnalysis.average(record.windows)
            currentTargets = EventAnalysis.targets(scores: currentScores, options: record.options)
        }
        latestRecord = record; status = "正在保存测试记录"
        let completed = record
        historyQueue.async { [weak self] in
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
        guard canConfigure, let record = latestRecord, record.material.inputMethod != .file else { return }
        preparing = true
        runner.clip { [weak self] samples in
            let result = Result { try AudioFileIO.saveWAV(samples: samples, sampleRate: Double(record.modelSampleRate)) }
            DispatchQueue.main.async {
                guard let self else { return }; self.preparing = false
                switch result {
                case .success(let url):
                    self.savedSampleURL = url
                    var updated = record; updated.material.savedAudioName = url.lastPathComponent
                    self.latestRecord = updated
                    self.historyQueue.async { [weak self] in
                        do { try SoundSessionStore.save(updated); DispatchQueue.main.async { self?.reloadHistory() } }
                        catch { DispatchQueue.main.async { self?.errorMessage = error.localizedDescription } }
                    }
                case .failure(let error): self.errorMessage = error.localizedDescription
                }
            }
        }
    }
    func reloadHistory(recoverInterrupted: Bool = false) {
        historyQueue.async { [weak self] in
            var recoveryError: String?
            if recoverInterrupted {
                do { try BatchLogStore.recoverInterrupted() }
                catch { recoveryError = "恢复上次批量日志失败：\(error.localizedDescription)" }
            }
            let records = SoundSessionStore.all()
            let groups = BatchLogStore.all()
            let warning = recoveryError
            DispatchQueue.main.async {
                guard let self, !self.deletingLogs else { return }
                var snapshot = SoundHistorySnapshot(records: records, groups: groups)
                if self.batchActive, let active = self.activeBatchGroup {
                    snapshot.groups.removeAll { $0.id == active.id }; snapshot.groups.append(active)
                    snapshot.groups.sort { $0.startedAt > $1.startedAt }
                }
                self.historySnapshot = snapshot
                if let warning { self.errorMessage = warning }
            }
        }
    }
    func delete(_ record: SoundRecord) {
        mutateLogs {
            try SoundSessionStore.delete(record)
        }
    }

    func clearLogs() {
        mutateLogs {
            try SoundSessionStore.clear()
            if FileManager.default.fileExists(atPath: BatchLogStore.exportDirectory.path) {
                try FileManager.default.removeItem(at: BatchLogStore.exportDirectory)
            }
        }
    }

    /// Run behind pending saves and freeze new mutations until the ZIP snapshot is ready.
    func exportAllLogs(completion: @escaping (URL) -> Void) {
        guard canExportLogs else { return }
        exportingLogs = true
        historyQueue.async { [weak self] in
            let result = Result { try AllLogsExport.create() }
            DispatchQueue.main.async {
                guard let self else {
                    if case .success(let url) = result { Self.removeLogExport(url) }
                    return
                }
                self.exportingLogs = false
                switch result {
                case .success(let url): completion(url)
                case .failure(let error): self.errorMessage = "导出全部日志失败：\(error.localizedDescription)"
                }
            }
        }
    }

    static func removeLogExport(_ url: URL) {
        DispatchQueue.global(qos: .utility).async { AllLogsExport.cleanup(url) }
    }

    /// Serialize writes, deletion and reload. One immutable snapshot replaces the
    /// list after disk work finishes; repeated gestures cannot launch competing deletes.
    private func mutateLogs(_ operation: @escaping () throws -> Void) {
        guard canDeleteLogs else { return }
        deletingLogs = true
        historyQueue.async { [weak self] in
            let result = Result { try operation() }
            let snapshot = SoundHistorySnapshot(records: SoundSessionStore.all(), groups: BatchLogStore.all())
            DispatchQueue.main.async {
                guard let self else { return }
                self.historySnapshot = snapshot
                if let latest = self.latestRecord, !snapshot.records.contains(where: { $0.id == latest.id }) { self.latestRecord = nil }
                if let group = self.activeBatchGroup, !snapshot.groups.contains(where: { $0.id == group.id }) { self.activeBatchGroup = nil }
                self.deletingLogs = false
                if case .failure(let error) = result { self.errorMessage = "日志清理未完成：\(error.localizedDescription)" }
            }
        }
    }

    // MARK: - Sequential WAV batches
    func importBatch(_ urls: [URL]) {
        guard canConfigure, !urls.isEmpty else { return }
        preparing = true; status = "准备批量 WAV 文件"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try BatchImport.stage(urls) }
            DispatchQueue.main.async {
                guard let self else {
                    if case .success(let selection) = result { BatchImport.remove(selection) }
                    return
                }
                self.preparing = false
                switch result {
                case .success(let selection):
                    let previous = self.batchSelection
                    self.batchSelection = selection; self.batchFiles = selection.files
                    self.activeBatchGroup = nil; self.batchName = ""
                    self.status = "已导入 \(selection.files.count) 个文件，可开始本轮测试"
                    DispatchQueue.global(qos: .utility).async { BatchImport.remove(previous) }
                case .failure(let error):
                    self.status = "批量导入失败"; self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func clearBatch() {
        guard canConfigure else { return }
        let previous = batchSelection
        batchSelection = nil; batchFiles = []; activeBatchGroup = nil; batchName = ""
        DispatchQueue.global(qos: .utility).async { BatchImport.remove(previous) }
    }

    func analyzeBatch() {
        guard ready, canConfigure, !batchFiles.isEmpty else { return }
        do {
            batchTemplate = try makeRecord(file: false) // Freeze this round's model and settings.
            persistOptions(); resetForRun()
            batchActive = true; batchWaitingForRunner = false; batchStopReason = nil; batchIndex = 0
            let name = batchName.trimmingCharacters(in: .whitespacesAndNewlines)
            let defaultName = "批量测试 \(Date().formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute().second()))"
            activeBatchGroup = BatchLogGroup(name: name.isEmpty ? defaultName : String(name.prefix(120)),
                model: model, options: options,
                items: batchFiles.map { BatchLogItem(id: $0.id, filename: $0.filename) })
            status = "建立本轮日志组"
            persistActiveBatch { [weak self] in self?.runNextBatchFile() }
        } catch { errorMessage = error.localizedDescription }
    }

    private func publishBatchGroup() {
        guard let group = activeBatchGroup else { return }
        var snapshot = historySnapshot
        snapshot.groups.removeAll { $0.id == group.id }
        snapshot.groups.append(group); snapshot.groups.sort { $0.startedAt > $1.startedAt }
        historySnapshot = snapshot
    }

    private func persistActiveBatch(then completion: @escaping () -> Void) {
        guard let group = activeBatchGroup else { return }
        publishBatchGroup()
        historyQueue.async { [weak self] in
            let result = Result { try BatchLogStore.save(group) }
            DispatchQueue.main.async {
                guard let self, self.batchActive, self.activeBatchGroup?.id == group.id else { return }
                switch result {
                case .success: completion()
                case .failure(let error):
                    // Never continue if the grouping metadata cannot be saved.
                    let message = "日志组保存失败，本轮已停止：\(error.localizedDescription)"
                    self.activeBatchGroup?.stopUnfinished(reason: message, interrupted: true)
                    self.publishBatchGroup(); self.batchActive = false; self.busy = false
                    self.preparing = false; self.finishing = false; self.batchTemplate = nil
                    self.status = "日志组保存失败"; self.errorMessage = message
                }
            }
        }
    }

    private func runNextBatchFile() {
        guard batchActive, let group = activeBatchGroup, let template = batchTemplate else { return }
        if batchStopReason != nil || batchIndex >= batchFiles.count { finishBatch(); return }
        let index = batchIndex, file = batchFiles[index], groupID = group.id
        preparing = true; finishing = false
        currentScores = []; currentTargets = []; recentWindows = []; events = []
        latestRecord = nil; savedSampleURL = nil; audioSeconds = 0; inferenceMS = 0
        activeBatchGroup?.items[index].status = .preparing
        status = "读取 \(index + 1)/\(batchFiles.count) · \(file.filename)"
        persistActiveBatch { [weak self] in
            guard let self else { return }
            if self.batchStopReason != nil { self.finishBatch(); return }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let result = Result { () -> (DecodedAudio, String) in
                    if let error = file.importError { throw SoundError.message(error) }
                    guard let url = file.localURL else { throw SoundError.message("临时音频不可用，请重新导入。") }
                    return (try AudioFileIO.load(url: url, sampleRate: Double(template.model.sampleRate)), try SoundModelStore.sha256(url))
                }
                DispatchQueue.main.async {
                    guard let self, self.batchActive, self.activeBatchGroup?.id == groupID else { return }
                    self.preparing = false
                    if self.batchStopReason != nil { self.finishBatch(); return }
                    switch result {
                    case .failure(let error):
                        self.activeBatchGroup?.items[index].status = .failed
                        self.activeBatchGroup?.items[index].error = error.localizedDescription
                        self.batchIndex += 1
                        self.persistActiveBatch { [weak self] in self?.runNextBatchFile() }
                    case .success(let (audio, hash)):
                        var record = template
                        record.id = UUID().uuidString; record.startedAt = Date()
                        record.actualInput = "本地 WAV 批量导入（未经过麦克风）"; record.actualInputUID = "file"
                        record.material.inputMethod = .file
                        record.material.filename = file.filename; record.material.sha256 = hash
                        record.material.originalSampleRate = audio.originalSampleRate; record.material.originalChannels = audio.channels
                        record.material.sampleID = (file.filename as NSString).deletingPathExtension
                        // A mixed batch must not inherit one file's manual category or Sxx meaning.
                        record.material.testCase = "批量文件"; record.material.testCaseVersion = nil
                        record.material.manualLabel = ""; record.material.savedAudioName = nil
                        record.thermalStart = Self.thermal
                        record.batteryStart = UIDevice.current.batteryLevel >= 0 ? UIDevice.current.batteryLevel : nil
                        record.batch = BatchRecordLink(groupID: groupID, itemID: file.id, index: index, total: group.items.count)
                        self.activeBatchGroup?.items[index].recordID = record.id
                        self.activeBatchGroup?.items[index].audioSeconds = audio.duration
                        self.activeBatchGroup?.items[index].status = .analyzing
                        self.status = "分析 \(index + 1)/\(self.batchFiles.count) · \(file.filename)"
                        let preparedRecord = record
                        self.persistActiveBatch { [weak self] in
                            guard let self else { return }
                            if self.batchStopReason != nil {
                                self.activeBatchGroup?.items[index].recordID = nil
                                self.finishBatch(); return
                            }
                            self.batchWaitingForRunner = true
                            self.runner.begin(preparedRecord, isLive: false) { [weak self] in
                                DispatchQueue.main.async {
                                    guard let self else { return }
                                    // begin resets the runner's cancel flag. Reapply a stop requested
                                    // between begin being queued and the first audio window.
                                    if let reason = self.batchStopReason { self.runner.requestCancel(reason: reason) }
                                    self.runner.analyzeFile(audio.samples)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func completeBatchRecord(_ original: SoundRecord) {
        guard batchActive, let link = original.batch, activeBatchGroup?.id == link.groupID,
              activeBatchGroup?.items.indices.contains(link.index) == true else { return }
        batchWaitingForRunner = false
        var record = original; record.thermalEnd = Self.thermal
        if let reason = batchStopReason, record.error == nil { record.error = reason; record.status = "已停止" }
        latestRecord = record; events = record.events; audioSeconds = record.audioSeconds; inferenceMS = record.inferenceMS
        recentWindows = Array(record.windows.suffix(80))
        if record.options.mode == .segment && record.model.task == .events {
            currentScores = EventAnalysis.average(record.windows)
            currentTargets = EventAnalysis.targets(scores: currentScores, options: record.options)
        }
        status = "保存 \(link.index + 1)/\(link.total) · \(record.material.filename ?? "")"
        let completed = record
        historyQueue.async { [weak self] in
            let result = Result { try SoundSessionStore.save(completed) }
            DispatchQueue.main.async {
                guard let self, self.batchActive, self.activeBatchGroup?.id == link.groupID else { return }
                self.activeBatchGroup?.items[link.index].audioSeconds = completed.audioSeconds
                self.activeBatchGroup?.items[link.index].inferenceMS = completed.inferenceMS
                switch result {
                case .success:
                    self.activeBatchGroup?.items[link.index].status = self.batchStopReason != nil ? .stopped : completed.error == nil ? .completed : .failed
                    self.activeBatchGroup?.items[link.index].error = completed.error
                case .failure(let error):
                    self.activeBatchGroup?.items[link.index].status = .failed
                    self.activeBatchGroup?.items[link.index].recordID = nil
                    self.activeBatchGroup?.items[link.index].error = "日志保存失败：\(error.localizedDescription)"
                    self.batchStopReason = "单条日志保存失败，本轮停止。"
                    self.errorMessage = "日志保存失败：\(error.localizedDescription)"
                }
                self.batchIndex += 1
                self.persistActiveBatch { [weak self] in self?.runNextBatchFile() }
            }
        }
    }

    private func finishBatch() {
        guard batchActive else { return }
        if let reason = batchStopReason { activeBatchGroup?.stopUnfinished(reason: reason) }
        else { activeBatchGroup?.status = .completed; activeBatchGroup?.endedAt = Date() }
        finishing = true; preparing = false
        persistActiveBatch { [weak self] in
            guard let self else { return }
            self.batchActive = false; self.busy = false; self.finishing = false
            self.batchTemplate = nil; self.batchWaitingForRunner = false
            self.status = "\(self.activeBatchGroup?.status.rawValue ?? "已结束") · \(self.activeBatchGroup?.summary ?? "")"
            self.reloadHistory()
        }
    }

    func deleteBatch(_ id: String) {
        mutateLogs { try BatchLogStore.delete(id) }
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

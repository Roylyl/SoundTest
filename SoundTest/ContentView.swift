import SwiftUI
import UniformTypeIdentifiers
import Charts

struct ContentView: View {
    @EnvironmentObject private var app: SoundController
    var body: some View {
        TabView {
            NavigationStack { TestView() }.tabItem { Label("测试", systemImage: "waveform") }
            NavigationStack { HistoryView() }.tabItem { Label("日志及模型信息", systemImage: "list.bullet.rectangle") }
            NavigationStack { SettingsView() }.tabItem { Label("设置", systemImage: "slider.horizontal.3") }
        }.tint(.blue)
        .alert("SoundTest", isPresented: Binding(get: { app.errorMessage != nil }, set: { if !$0 { app.errorMessage = nil } })) {
            Button("知道了") { app.errorMessage = nil }
        } message: { Text(app.errorMessage ?? "") }
    }
}

struct TestView: View {
    @EnvironmentObject private var app: SoundController
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var importing = false
    @State private var importingBatch = false
    @State private var choosingModel = false

    var body: some View {
        GeometryReader { geometry in
            if sizeClass == .regular && geometry.size.width >= 900 {
                HStack(alignment: .top, spacing: 20) {
                    ScrollView {
                        controls.padding(.vertical, 18)
                    }
                    .frame(width: min(440, geometry.size.width * 0.42))
                    .accessibilityIdentifier("testControlsColumn")
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            HStack {
                                Text("识别结果").font(.title3.bold())
                                Spacer()
                                Text(app.options.mode.rawValue).font(.caption).foregroundStyle(.secondary)
                            }
                            results
                        }
                        .frame(maxWidth: 800, alignment: .leading)
                        .padding(20)
                        .background(.background, in: RoundedRectangle(cornerRadius: 24))
                        .padding(.vertical, 18)
                        .frame(maxWidth: .infinity, alignment: .top)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("testResultsColumn")
                }
                .padding(.horizontal, 24)
                .frame(maxWidth: 1300, maxHeight: .infinity, alignment: .top)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        controls
                        results
                    }
                    .frame(maxWidth: 720, alignment: .leading)
                    .padding(18)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .background(SoundBackdrop())
        .navigationTitle("SoundTest")
        .fileImporter(isPresented: $importing, allowedContentTypes: importingBatch ? [.wav] : [.audio], allowsMultipleSelection: importingBatch) { result in
            switch result {
            case .success(let urls):
                if importingBatch { app.importBatch(urls) }
                else if let url = urls.first { app.importAudio(url) }
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError { app.errorMessage = error.localizedDescription }
            }
        }
        .sheet(isPresented: $choosingModel) { NavigationStack { ModelPickerView() } }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 18) {
            TaskPicker().disabled(!app.canConfigure)
            Button { choosingModel = true } label: {
                HStack(spacing: 14) {
                    Image(systemName: "waveform.circle.fill").font(.largeTitle)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("当前模型 · \(app.model.number)").font(.caption).foregroundStyle(.secondary)
                        Text(app.model.title).font(.headline).foregroundStyle(.primary)
                        Text(app.status).font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    if app.preparing { ProgressView() } else { Image(systemName: "chevron.up.chevron.down") }
                }.padding(18)
            }.buttonStyle(.plain).soundGlass().disabled(!app.canConfigure)
                .accessibilityIdentifier("modelSelector")

            VStack(alignment: .leading, spacing: 12) {
                Picker("测试模式", selection: $app.options.mode) {
                    ForEach(AnalysisMode.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).disabled(!app.canConfigure)
                Text(app.task == .scenes ? "32 kHz · 1秒分析窗；保留原始Top-3与平滑结果。首次需要积累窗口，低分或候选接近时显示不确定。" : (app.options.mode == .segment ? "录音结束后按配置窗口分析，汇总显示各窗口平均分。" : "持续采集所有声音，按窗口更新；可同时提示多类。"))
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Label(app.batchActive ? "本地 WAV 批量导入 · 不使用麦克风" : app.actualInput, systemImage: app.batchActive ? "doc.on.doc" : "mic").font(.caption).lineLimit(2)
                    Spacer()
                    Button { app.refreshInputs() } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("刷新输入源")
                }
                if app.busy {
                    Button { app.stop() } label: { Label(app.batchActive ? "停止本轮批量测试" : app.recording ? "停止录音" : "停止分析", systemImage: "stop.fill").frame(maxWidth: .infinity).padding(.vertical, 8) }
                        .soundButton(prominent: true).tint(.red).disabled(app.finishing).accessibilityIdentifier("stop")
                } else {
                    Button { app.startRecording() } label: { Label("开始录音", systemImage: "mic.fill").frame(maxWidth: .infinity).padding(.vertical, 8) }
                        .soundButton(prominent: true).disabled(!app.ready || !app.canConfigure).accessibilityIdentifier("record")
                }
                HStack {
                    metric("音频时长", timeText(app.audioSeconds))
                    metric("推理调用", msText(app.inferenceMS))
                    metric("窗口 / 步长", "\(app.options.windowSeconds.formatted()) / \(app.options.stepSeconds.formatted()) s")
                }
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(.background, in: RoundedRectangle(cornerRadius: 22))

            VStack(alignment: .leading, spacing: 10) {
                Text("本地音频").font(.headline)
                HStack {
                    Button("单个音频", systemImage: "doc.badge.plus") { importingBatch = false; importing = true }
                        .soundButton().accessibilityIdentifier("importSingle")
                    Button("批量 WAV", systemImage: "doc.on.doc") { importingBatch = true; importing = true }
                        .soundButton().accessibilityIdentifier("importBatch")
                }.disabled(!app.canConfigure)
                if let audio = app.imported {
                    Text(audio.filename).font(.subheadline).textSelection(.enabled)
                    Text("\(timeText(audio.duration)) · \(Int(audio.originalSampleRate)) Hz · \(audio.channels) 声道").font(.caption).foregroundStyle(.secondary)
                    Button("使用当前模型分析", systemImage: "play.fill") { app.analyzeImported() }.soundButton().disabled(!app.ready || !app.canConfigure)
                } else { Text("导入同一份 WAV、M4A 等系统支持的音频，切换模型后可重复分析。").font(.caption).foregroundStyle(.secondary) }
                if !app.batchFiles.isEmpty { Divider(); BatchImportPanel() }
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(.background, in: RoundedRectangle(cornerRadius: 22))

            DisclosureGroup("测试用例与素材信息") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("用例", selection: $app.material.testCase) {
                        ForEach(app.task == .events ? SoundTestCase.all : SceneTestCases.all) { Text("\($0.id) · \($0.name)").tag($0.id) }
                    }
                    Picker("录音方式", selection: $app.material.inputMethod) {
                        Text(InputMethod.environment.rawValue).tag(InputMethod.environment)
                        Text(InputMethod.playback.rawValue).tag(InputMethod.playback)
                    }
                    TextField("样本编号（如 S01-01）", text: $app.material.sampleID)
                    TextField("人工参考标签（仅记录）", text: $app.material.manualLabel)
                    TextField("来源 / 播放设备 / 环境", text: $app.material.source)
                    TextField("素材使用许可或授权", text: $app.material.permission)
                    Text("文件名、编号与人工标签只进入日志，不参与预测。文件分析自动标为“直接导入”。").font(.caption).foregroundStyle(.secondary)
                }.padding(.top, 10).disabled(!app.canConfigure)
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(.background, in: RoundedRectangle(cornerRadius: 22))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 18) {
            if app.task == .scenes {
                SceneResultView(windows: app.recentWindows)
            } else if !app.top5.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack { Text("模型原始 Top-5（调试）").font(.headline); Spacer(); NavigationLink("全部类别") { AllScoresView(scores: app.currentScores) } }
                    Text(app.latestRecord?.options.mode == .segment ? "整段窗口平均分 · 分数不是准确率" : "最近分析窗口 · 分数不是准确率").font(.caption).foregroundStyle(.secondary)
                    ForEach(app.top5) { ScoreRow(score: $0) }
                }.padding(18).background(.background, in: RoundedRectangle(cornerRadius: 22))
                VStack(alignment: .leading, spacing: 12) {
                    Text("重点类别").font(.headline)
                    ForEach(app.currentTargets) { TargetRow(target: $0) }
                    Text("仅提示猫狗叫声、咳嗽、笑声和鼓掌。猫狗叫声会聚合具体叫声标签，并在日志中保留本窗分数最高的原始标签；Dog、Cat 等宽泛父类不代替叫声命中。").font(.caption).foregroundStyle(.secondary)
                }.padding(18).background(.background, in: RoundedRectangle(cornerRadius: 22))
            } else {
                ContentUnavailableView("等待声音测试", systemImage: "waveform.path", description: Text("猫狗叫声、咳嗽、笑声、鼓掌\n结果及重点类别分数将在这里显示。"))
            }
            if !app.events.isEmpty { TimelineView(events: Array(app.events.suffix(40))) }
            if !app.recentWindows.isEmpty {
                DisclosureGroup("分析窗口 · 最近 \(app.recentWindows.count) 个") {
                    ForEach(app.recentWindows.reversed()) { window in
                        NavigationLink { WindowDetail(window: window) } label: { WindowRow(window: window) }
                    }
                }.padding(18).background(.background, in: RoundedRectangle(cornerRadius: 22))
            }
            if let record = app.latestRecord, !app.busy {
                HStack {
                    ShareLink(item: SoundSessionStore.url(record.id)) { Label("分享记录", systemImage: "square.and.arrow.up") }.soundButton()
                    if record.material.inputMethod != .file && record.audioSeconds <= 60 {
                        Button("保存测试片段", systemImage: "square.and.arrow.down") { app.saveSample() }.soundButton().disabled(app.preparing)
                    }
                }
                if let url = app.savedSampleURL { ShareLink("分享已保存的音频", item: url) }
            }
            Text("麦克风音频默认不落盘。60秒以内的本轮录音可主动保存；更长的复现素材请直接导入。连续录音前台最多30分钟，导入最多10分钟。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(label).font(.caption2).foregroundStyle(.secondary); Text(value).font(.caption.monospacedDigit()) }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ModelPickerView: View {
    @EnvironmentObject private var app: SoundController
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        List(app.taskModels) { id in
            Button { app.selectModel(id); dismiss() } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 5) { Text("\(id.number) · \(id.title)"); Text(id.framework).font(.caption).foregroundStyle(.secondary) }
                    Spacer(); if id == app.model { Image(systemName: "checkmark") }
                }.padding(.vertical, 6)
            }.disabled(!app.canConfigure).accessibilityIdentifier("model.\(id.rawValue)")
        }.navigationTitle(app.task.rawValue + "模型").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var app: SoundController
    @Environment(\.horizontalSizeClass) private var sizeClass
    var body: some View {
        Form {
            Section("任务") { TaskPicker() }
            Section("模型") {
                NavigationLink { ModelPickerView() } label: { LabeledContent("当前模型", value: app.model.title) }
                Text("按任务选择内置模型，离线切换，一次只加载一组。").font(.caption).foregroundStyle(.secondary)
            }
            Section("麦克风输入") {
                Picker("输入源", selection: Binding(get: { app.preferredUID }, set: { app.chooseInput($0) })) {
                    Text("系统默认").tag("")
                    ForEach(app.inputs) { Text($0.name).tag($0.id) }
                }
                LabeledContent("实际输入", value: app.actualInput)
                Button("刷新输入源", systemImage: "arrow.clockwise") { app.refreshInputs() }
                Text("进入前台及路由变化时自动刷新；实际录音路由写入每条日志。录音中路由变化会结束本轮。").font(.caption).foregroundStyle(.secondary)
            }
            Section("分析参数") {
                if app.model == .cpMobile { LabeledContent("原生窗口", value: "1 s · 32,000 samples") }
                else if app.model == .yamnet { LabeledContent("原生窗口", value: "0.975 s · 15,600 samples") }
                else if app.model == .efficientAT { LabeledContent("本版输入窗口", value: "10 s · 320,000 samples") }
                else { Stepper("分析窗口：\(app.options.windowSeconds.formatted()) s", value: $app.options.windowSeconds, in: 1...30, step: 1) }
                Picker("步长", selection: $app.options.stepSeconds) {
                    ForEach((app.model == .cpMobile ? [0.5, 1] : app.model == .yamnet ? [0.24, 0.48, 0.975] : app.model == .efficientAT ? [2, 5, 10] : [0.5, 1, 2, 5, 10]).filter { $0 <= app.options.windowSeconds }, id: \.self) { Text("\($0.formatted()) s").tag($0) }
                }
                if app.task == .events { Stepper("同类合并间隔：\(app.options.mergeGapSeconds.formatted()) s", value: $app.options.mergeGapSeconds, in: 0...5, step: 0.25) }
                Stepper("CPU线程：\(app.options.threads)", value: $app.options.threads, in: 1...4)
                Text("窗口影响短声稀释和首次等待。尾窗补零并保留有效音频范围；不使用语音VAD。更小步长会增加计算量。").font(.caption).foregroundStyle(.secondary)
                Button("应用设置") { app.applySettings() }
                Button("恢复当前模型默认值") { app.restoreDefaults() }
            }
            if app.task == .scenes { SceneSettings() }
            if app.task == .events { Section("类别阈值") {
                ForEach(TargetCategory.all) { target in
                    VStack(alignment: .leading) {
                        HStack { Text(target.chinese); Spacer(); Text(thresholdText(app.options.thresholds[target.id])).monospacedDigit() }
                        Slider(value: Binding(get: { app.options.thresholds[target.id] ?? 0.3 }, set: { app.options.thresholds[target.id] = $0 }), in: 0...1, step: 0.01)
                    }
                }
                Text("0.30仅为观察起点，尚未按真机素材校准。四个业务目标独立判断并支持重叠；同一目标包含多个原始标签时取本窗最高分用于提示，完整原始分数仍写入日志。").font(.caption).foregroundStyle(.secondary)
            }
            }
            Section("文件与版本") {
                Text("权重与类别表随App内置；加载前核对字节数及SHA256。替换模型需更新清单后重新构建。")
                LabeledContent("SoundTest", value: "2.0.0")
                LabeledContent("中文显示映射", value: ChineseLabels.version)
                LabeledContent("模型输入", value: "\(app.model.sampleRate) Hz · 单声道 Float32")
                Text("模型分数、音频时长、推理耗时均保留原始口径。EfficientAT 为片段分类，连续模式的事件时间由应用分窗估计。")
            }
        }
        .frame(maxWidth: sizeClass == .regular ? 1000 : .infinity)
        .frame(maxWidth: .infinity)
        .background(SoundBackdrop())
        .disabled(!app.canConfigure).navigationTitle("设置")
        .onChange(of: app.options.windowSeconds) { _, value in if app.options.stepSeconds > value { app.options.stepSeconds = value } }
    }
}

struct HistoryView: View {
    @EnvironmentObject private var app: SoundController
    @EnvironmentObject private var watchInbox: WatchLogInbox
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var deletion: LogDeletion?
    @State private var exportedArchive: BatchShareFile?
    @State private var archiveToRemove: URL?
    private var singleRecords: [SoundRecord] {
        let groupedIDs = Set(app.batchHistory.map(\.id))
        return app.history.filter { $0.batch.map { !groupedIDs.contains($0.groupID) } ?? true }
    }
    var body: some View {
        List {
            Section("批量测试 · \(app.batchHistory.count) 组") {
                if app.batchHistory.isEmpty { Text("批量导入 WAV 并开始测试后，每轮自动生成一个日志组。").foregroundStyle(.secondary) }
                ForEach(app.batchHistory) { group in
                    NavigationLink { BatchGroupDetail(id: group.id) } label: { BatchGroupRow(group: group) }
                        .accessibilityIdentifier("batchGroup.\(group.id)")
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) { deleteButton(.group(group)) }
                        .swipeActions(edge: .leading, allowsFullSwipe: false) { deleteButton(.group(group)) }
                }
            }
            Section("单条测试 · \(singleRecords.count)") {
                if singleRecords.isEmpty { Text("录音和单文件分析仍单独保存。").foregroundStyle(.secondary) }
                ForEach(singleRecords) { record in NavigationLink { LoadRecordView(id: record.id) } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("\(record.effectiveTask.rawValue) · \(record.material.testCase) · \(record.model.title)").font(.headline)
                        Text(record.material.filename ?? record.material.inputMethod.rawValue).lineLimit(1)
                        Text("\(record.startedAt.formatted(date: .numeric, time: .shortened)) · \(timeText(record.audioSeconds)) · \(record.status)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                    .accessibilityIdentifier("historyRecord.\(record.id)")
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) { deleteButton(.record(record)) }
                    .swipeActions(edge: .leading, allowsFullSwipe: false) { deleteButton(.record(record)) }
                }
            }
            Section("内置模型信息") {
                ForEach(app.assets) { asset in NavigationLink { ModelInfoView(asset: asset) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(SoundModelID(rawValue: asset.id)?.title ?? asset.id)
                        Text("\(app.availableModels.contains(SoundModelID(rawValue: asset.id) ?? .zipformer) ? "内置文件完整" : "文件缺失或大小不符") · \(ByteCountFormatter.string(fromByteCount: asset.bytes, countStyle: .file))").font(.caption).foregroundStyle(.secondary)
                    }
                } }
            }
            Section {
                Button {
                    app.exportAllLogs { url in
                        archiveToRemove = url
                        exportedArchive = BatchShareFile(url: url)
                    }
                } label: {
                    if app.exportingLogs { ProgressView("正在打包全部日志") }
                    else { Label("导出全部日志（ZIP）", systemImage: "square.and.arrow.up") }
                }.disabled(!app.canExportLogs).accessibilityIdentifier("exportAllLogs")
            } footer: {
                Text("打包当前全部单条日志和批量日志组，包含完整原始分数、配置、耗时与异常；不包含音频和模型文件。测试或保存结束后可导出。")
            }
            Section {
                Button {
                    deletion = .all(records: app.history.count, groups: app.batchHistory.count)
                } label: {
                    if app.deletingLogs { Label("正在清理日志", systemImage: "hourglass") }
                    else { Label("清空日志", systemImage: "trash") }
                }.foregroundStyle(.red).disabled(!app.canDeleteLogs).accessibilityIdentifier("clearLogs")
            } footer: {
                Text("清空全部单条记录和批量日志组，保留模型与音频文件。测试或保存进行中暂不可清空。")
            }
            Section {
                NavigationLink {
                    WatchLogsView()
                } label: {
                    HStack {
                        Label("查看 Apple Watch 上的日志", systemImage: "applewatch")
                        Spacer()
                        Text("\(watchInbox.logs.count)").foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("watchLogs")
            } footer: {
                Text("手表上主动导出后，配对 iPhone 接收并保存的日志会出现在这里；与 iPhone 测试日志分开存放。")
            }
        }
        .frame(maxWidth: sizeClass == .regular ? 1000 : .infinity)
        .frame(maxWidth: .infinity)
        .background(SoundBackdrop())
        .navigationTitle("日志及模型信息").refreshable { app.reloadHistory(); watchInbox.refresh() }
        .sheet(item: $exportedArchive, onDismiss: {
            if let url = archiveToRemove { SoundController.removeLogExport(url) }
            archiveToRemove = nil
        }) { file in BatchShareSheet(url: file.url) }
        .alert(deletion?.title ?? "删除日志？", isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } })) {
            if let request = deletion { Button(request.buttonTitle, role: .destructive) { performDeletion(request) } }
            Button("取消", role: .cancel) { deletion = nil }
        } message: { Text(deletion?.message ?? "") }
    }
    private func deleteButton(_ request: LogDeletion) -> some View {
        // A destructive-role swipe button optimistically removes its List row before
        // async disk work finishes. Keep the row stable until a confirmed snapshot arrives.
        Button(request.swipeTitle) { deletion = request }
            .tint(.red).disabled(!app.canDeleteLogs)
            .accessibilityIdentifier("requestLogDelete")
    }
    private func performDeletion(_ request: LogDeletion) {
        deletion = nil
        // Let the swipe/confirmation transaction close before updating the data source.
        DispatchQueue.main.async {
            switch request {
            case .record(let record): app.delete(record)
            case .group(let group): app.deleteBatch(group.id)
            case .all: app.clearLogs()
            }
        }
    }
}

private enum LogDeletion {
    case record(SoundRecord), group(BatchLogGroup), all(records: Int, groups: Int)
    var title: String {
        switch self { case .record: return "删除这条日志？"; case .group: return "删除整组日志？"; case .all: return "清空全部日志？" }
    }
    var swipeTitle: String { if case .group = self { return "删除整组" }; return "删除" }
    var buttonTitle: String {
        switch self { case .record: return "确认删除这条日志"; case .group: return "确认删除整组日志"; case .all: return "确认清空全部日志" }
    }
    var message: String {
        switch self {
        case .record(let record): return "将删除“\(record.material.filename ?? record.model.title)”的测试记录，原始音频保留。"
        case .group(let group): return "将删除“\(group.name)”及组内 \(group.items.count) 个文件的日志。原始音频和其他轮次保留。"
        case .all(let records, let groups): return "将删除 \(records) 条测试记录、\(groups) 个批量日志组及已生成的日志分享副本。此操作不可撤销，模型和音频文件保留。"
        }
    }
}

struct ModelInfoView: View {
    let asset: SoundModelAsset
    @EnvironmentObject private var app: SoundController
    var body: some View {
        List {
            Section("模型") {
                LabeledContent("名称", value: SoundModelID(rawValue: asset.id)?.title ?? asset.id)
                LabeledContent("推理版本", value: asset.frameworkVersion)
                LabeledContent("版本", value: asset.revision)
                LabeledContent("文件状态", value: app.availableModels.contains(SoundModelID(rawValue: asset.id) ?? .zipformer) ? "内置文件完整；加载前校验SHA256" : "文件不完整")
                LabeledContent("必要文件", value: ByteCountFormatter.string(fromByteCount: asset.bytes, countStyle: .file))
                Text(asset.id == "cpMobile" ? "十类声学场景分类 · unknown通用分支 · 32 kHz / 1秒窗。" + SceneAnalysis.coverage : "多标签片段分类；连续模式由应用分窗。时间边界是估计，非模型原生SED输出。").font(.caption)
                Text(asset.license).font(.caption)
                if let url = URL(string: asset.source) { Link("模型来源", destination: url) }
            }
            Section("内置文件与校验") {
                ForEach(asset.files, id: \.path) { file in VStack(alignment: .leading, spacing: 6) {
                    Text(file.path).font(.headline)
                    Text("\(file.bytes) bytes").font(.caption)
                    Text("SHA256 \(file.sha256)").font(.caption2.monospaced()).textSelection(.enabled)
                    if let url = URL(string: file.source) { Link("文件来源", destination: url) }
                } }
            }
        }.navigationTitle("模型信息").navigationBarTitleDisplayMode(.inline)
    }
}

struct RecordDetail: View {
    let record: SoundRecord
    var body: some View {
        List {
            Section("本轮配置") {
                LabeledContent("任务", value: record.effectiveTask.rawValue)
                LabeledContent("模型", value: record.model.title)
                LabeledContent("时间", value: record.startedAt.formatted())
                LabeledContent("状态", value: record.status)
                LabeledContent("设备", value: record.device)
                LabeledContent("实际输入", value: record.actualInput)
                LabeledContent("输入方式", value: record.material.inputMethod.rawValue)
                if let batch = record.batch {
                    LabeledContent("批量序号", value: "\(batch.index + 1) / \(batch.total)")
                    NavigationLink("查看本轮日志组") { BatchGroupDetail(id: batch.groupID) }
                }
                LabeledContent("测试编号", value: record.material.testCase)
                LabeledContent("样本编号", value: record.material.sampleID)
                LabeledContent("文件", value: record.material.filename ?? "麦克风未保存文件")
                LabeledContent("人工标签", value: record.material.manualLabel)
                LabeledContent("来源 / 许可", value: "\(record.material.source) · \(record.material.permission)")
                LabeledContent("模式", value: record.options.mode.rawValue)
                LabeledContent("窗口 / 步长", value: "\(record.options.windowSeconds) / \(record.options.stepSeconds) s")
                if record.effectiveTask == .events {
                    LabeledContent("合并间隔", value: timeText(record.options.mergeGapSeconds))
                    ForEach(TargetCategory.all) { target in LabeledContent(target.chinese + "阈值", value: thresholdText(record.options.thresholds[target.id])) }
                } else {
                    let smooth = record.options.scene ?? SceneOptions()
                    LabeledContent("平滑 / 确认窗口", value: "\(smooth.averagingWindows) / \(smooth.confirmationWindows)")
                    LabeledContent("最低分 / 候选差值", value: "\(smooth.minimumScore) / \(smooth.minimumMargin)")
                    LabeledContent("模型采样率", value: "\(record.modelSampleRate) Hz")
                }
                if let error = record.error { Text(error).foregroundStyle(.red) }
            }
            Section("指标") {
                LabeledContent("音频时长", value: timeText(record.audioSeconds))
                LabeledContent("模型加载与校验", value: msText(record.loadMS))
                LabeledContent("推理调用合计", value: msText(record.inferenceMS))
                LabeledContent("停止后等待", value: record.stopWaitMS.map(msText) ?? "不适用")
                LabeledContent("起止热状态", value: "\(record.thermalStart) → \(record.thermalEnd)")
                Text(record.metricDefinition).font(.caption).foregroundStyle(.secondary)
            }
            if record.effectiveTask == .scenes { Section("场景结果") { SceneResultView(windows: record.windows) } }
            if !record.events.isEmpty { Section("事件时间线") { TimelineView(events: Array(record.events.suffix(40))) } }
            Section("窗口结果 · \(record.windows.count)") {
                ForEach(record.windows) { window in NavigationLink { WindowDetail(window: window) } label: { WindowRow(window: window) } }
            }
            Section { ShareLink(item: SoundSessionStore.url(record.id)) { Label("分享完整 JSON（含全部原始分数）", systemImage: "square.and.arrow.up") } }
        }.navigationTitle("测试记录").navigationBarTitleDisplayMode(.inline)
    }
}

struct LoadRecordView: View {
    let id: String
    @State private var record: SoundRecord?
    @State private var error: String?
    var body: some View {
        Group {
            if let record { RecordDetail(record: record) }
            else if let error { ContentUnavailableView("日志无法读取", systemImage: "exclamationmark.triangle", description: Text(error)) }
            else { ProgressView("读取完整窗口记录") }
        }.task {
            do { record = try await Task.detached(priority: .userInitiated) { try SoundSessionStore.load(id) }.value }
            catch { self.error = error.localizedDescription }
        }
    }
}

struct WindowRow: View {
    let window: WindowResult
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("#\(window.index + 1) · \(timeText(window.start))–\(timeText(window.end))").font(.subheadline.monospacedDigit())
            Text(window.scene?.title ?? (window.targets.filter(\.prompted).map(\.chinese).joined(separator: "、").isEmpty ? "未提示目标类别" : window.targets.filter(\.prompted).map(\.chinese).joined(separator: "、"))).font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 4)
    }
}
struct WindowDetail: View {
    let window: WindowResult
    var body: some View {
        List {
            Section("有效音频窗口") {
                LabeledContent("音频位置", value: "\(timeText(window.start))–\(timeText(window.end))")
                LabeledContent("实际模型输入", value: timeText(window.modelInputSeconds))
                LabeledContent("补零", value: timeText(window.paddedSeconds))
                LabeledContent("推理调用", value: msText(window.inferenceMS))
                LabeledContent("窗口采集覆盖", value: window.windowCollectionSeconds.map(timeText) ?? "文件输入，不适用")
                LabeledContent("等待新音频（估计）", value: window.additionalAudioWaitMS.map(msText) ?? "不适用")
                LabeledContent("队列等待", value: window.queueDelayMS.map(msText) ?? "不适用")
                LabeledContent("窗尾至提示", value: window.presentedAt == nil && window.promptAfterWindowMS != nil ? "待本轮日志确认" : (window.promptAfterWindowMS.map(msText) ?? "不适用"))
                LabeledContent("真实事件延迟", value: "未测（需要独立起止标注）")
            }
            if let scene = window.scene {
                Section("场景判定") {
                    Text(scene.title)
                    LabeledContent("判定可用时间（音频位置）", value: timeText(scene.decisionAudioTime))
                    LabeledContent("平滑覆盖", value: "\(timeText(scene.averagingStart))–\(timeText(scene.averagingEnd))")
                    Text("原始与平滑分数均保留；此时间不是场景真实切换边界。").font(.caption)
                }
                Section("原始 Top-3") { ForEach(Array(window.top5.prefix(3))) { ScoreRow(score: $0) } }
                Section("平滑分数") { ForEach(scene.smoothedScores.sorted { $0.score > $1.score }) { ScoreRow(score: $0) } }
            } else {
                Section("Top-5") { ForEach(window.top5) { ScoreRow(score: $0) } }
                Section("四个业务目标") { ForEach(window.targets) { TargetRow(target: $0) } }
            }
            Section { NavigationLink("全部 \(window.scores.count) 类原始分数") { AllScoresView(scores: window.scores) } }
        }.navigationTitle("窗口 #\(window.index + 1)").navigationBarTitleDisplayMode(.inline)
    }
}
struct ScoreRow: View {
    let score: RawScore
    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) { Text(SceneAnalysis.labels.contains(score.label) ? SceneAnalysis.name(score.label) : ChineseLabels.name(score.label)); Text(score.label).font(.caption).foregroundStyle(.secondary) }
            Spacer(); Text(scoreText(score.score)).font(.body.monospacedDigit())
        }.accessibilityElement(children: .combine)
    }
}
struct TargetRow: View {
    let target: TargetScore
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) { Text(target.chinese); Text(target.originalLabel ?? "标签不支持 / 未返回").font(.caption).foregroundStyle(.secondary) }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) { Text(scoreText(target.score)).monospacedDigit(); Text(target.prompted ? "达到提示阈值" : "未提示").font(.caption).foregroundStyle(target.prompted ? .blue : .secondary) }
        }
    }
}
struct AllScoresView: View {
    let scores: [RawScore]
    @State private var query = ""
    var body: some View {
        List(scores.filter { query.isEmpty || $0.label.localizedCaseInsensitiveContains(query) || ChineseLabels.name($0.label).contains(query) }.sorted { $0.score > $1.score }) { ScoreRow(score: $0) }
            .navigationTitle("全部类别分数").searchable(text: $query, prompt: "中文或原始标签")
    }
}
struct TimelineView: View {
    let events: [EventEstimate]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("事件时间线 · 最多显示最近40条").font(.headline)
            Chart(events) { event in
                BarMark(xStart: .value("窗起", event.evidenceStart), xEnd: .value("窗止", event.evidenceEnd), y: .value("类别", event.chinese)).foregroundStyle(.blue.opacity(0.18))
                BarMark(xStart: .value("估计起", event.estimatedStart), xEnd: .value("估计止", event.estimatedEnd), y: .value("类别", event.chinese)).foregroundStyle(.blue)
            }.frame(height: CGFloat(max(160, Set(events.map(\.categoryID)).count * 45))).chartXAxisLabel("音频位置（秒）")
            Text("浅色为相关窗口覆盖；深色为按窗口中心和步长估计的范围，不是精确事件起止。多类独立保留；同类相邻提示按设置合并。").font(.caption).foregroundStyle(.secondary)
            ForEach(events.suffix(8)) { event in
                Text("\(event.chinese) · 窗口 \(timeText(event.evidenceStart))–\(timeText(event.evidenceEnd))；估计 \(timeText(event.estimatedStart))–\(timeText(event.estimatedEnd))").font(.caption)
            }
        }.padding(16).background(.background, in: RoundedRectangle(cornerRadius: 22))
    }
}

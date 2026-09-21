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
    @State private var importing = false
    @State private var choosingModel = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
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
                    Text(app.options.mode == .segment ? "录音结束后按配置窗口分析，汇总显示各窗口平均分。" : "持续采集所有声音，按窗口更新；可同时提示多类。")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Label(app.actualInput, systemImage: "mic").font(.caption).lineLimit(2)
                        Spacer()
                        Button { app.refreshInputs() } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("刷新输入源")
                    }
                    if app.busy {
                        Button { app.stop() } label: { Label(app.recording ? "停止录音" : "停止分析", systemImage: "stop.fill").frame(maxWidth: .infinity).padding(.vertical, 8) }
                            .soundButton(prominent: true).tint(.red).disabled(app.finishing).accessibilityIdentifier("stop")
                    } else {
                        Button { app.startRecording() } label: { Label("开始录音", systemImage: "mic.fill").frame(maxWidth: .infinity).padding(.vertical, 8) }
                            .soundButton(prominent: true).disabled(!app.ready || app.preparing).accessibilityIdentifier("record")
                    }
                    HStack {
                        metric("音频时长", timeText(app.audioSeconds))
                        metric("推理调用", msText(app.inferenceMS))
                        metric("窗口 / 步长", "\(app.options.windowSeconds.formatted()) / \(app.options.stepSeconds.formatted()) s")
                    }
                }.padding(18).background(.background, in: RoundedRectangle(cornerRadius: 22))

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("本地音频").font(.headline)
                        Spacer()
                        Button("导入", systemImage: "doc.badge.plus") { importing = true }.disabled(!app.canConfigure)
                    }
                    if let audio = app.imported {
                        Text(audio.filename).font(.subheadline).textSelection(.enabled)
                        Text("\(timeText(audio.duration)) · \(Int(audio.originalSampleRate)) Hz · \(audio.channels) 声道").font(.caption).foregroundStyle(.secondary)
                        Button("使用当前模型分析", systemImage: "play.fill") { app.analyzeImported() }.soundButton().disabled(!app.ready || !app.canConfigure)
                    } else { Text("导入同一份 WAV、M4A 等系统支持的音频，切换模型后可重复分析。").font(.caption).foregroundStyle(.secondary) }
                }.padding(18).background(.background, in: RoundedRectangle(cornerRadius: 22))

                DisclosureGroup("测试用例与素材信息") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("用例", selection: $app.material.testCase) {
                            ForEach(SoundTestCase.all) { Text("\($0.id) · \($0.name)").tag($0.id) }
                        }
                        Picker("录音方式", selection: $app.material.inputMethod) {
                            Text(InputMethod.environment.rawValue).tag(InputMethod.environment)
                            Text(InputMethod.playback.rawValue).tag(InputMethod.playback)
                        }
                        TextField("样本编号（如 K01）", text: $app.material.sampleID)
                        TextField("人工参考标签（仅记录）", text: $app.material.manualLabel)
                        TextField("来源 / 播放设备 / 环境", text: $app.material.source)
                        TextField("素材使用许可或授权", text: $app.material.permission)
                        Text("文件名、编号与人工标签只进入日志，不参与预测。文件分析自动标为“直接导入”。").font(.caption).foregroundStyle(.secondary)
                    }.padding(.top, 10).disabled(!app.canConfigure)
                }.padding(18).background(.background, in: RoundedRectangle(cornerRadius: 22))

                if !app.top5.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack { Text("Top-5 分数").font(.headline); Spacer(); NavigationLink("全部类别") { AllScoresView(scores: app.currentScores) } }
                        Text(app.latestRecord?.options.mode == .segment ? "整段窗口平均分 · 分数不是准确率" : "最近分析窗口 · 分数不是准确率").font(.caption).foregroundStyle(.secondary)
                        ForEach(app.top5) { ScoreRow(score: $0) }
                    }.padding(18).background(.background, in: RoundedRectangle(cornerRadius: 22))
                    VStack(alignment: .leading, spacing: 12) {
                        Text("重点类别").font(.headline)
                        ForEach(app.currentTargets.filter { $0.enabled }) { TargetRow(target: $0) }
                        Text("低于阈值时不提示目标；未返回分数保留为空。狗 Dog 父类与 Bark 分开记录。").font(.caption).foregroundStyle(.secondary)
                    }.padding(18).background(.background, in: RoundedRectangle(cornerRadius: 22))
                } else {
                    ContentUnavailableView("等待声音测试", systemImage: "waveform.path", description: Text("敲门、狗叫、咳嗽、汽车喇叭\n结果及重点类别分数将在这里显示。"))
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
            }.padding(18)
        }.background(SoundBackdrop()).navigationTitle("SoundTest")
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio]) { result in
            switch result { case .success(let url): app.importAudio(url); case .failure(let error): app.errorMessage = error.localizedDescription }
        }
        .sheet(isPresented: $choosingModel) { NavigationStack { ModelPickerView() } }
    }
    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(label).font(.caption2).foregroundStyle(.secondary); Text(value).font(.caption.monospacedDigit()) }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ModelPickerView: View {
    @EnvironmentObject private var app: SoundController
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        List(SoundModelID.allCases) { id in
            Button { app.selectModel(id); dismiss() } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 5) { Text("\(id.number) · \(id.title)"); Text(id.framework).font(.caption).foregroundStyle(.secondary) }
                    Spacer(); if id == app.model { Image(systemName: "checkmark") }
                }.padding(.vertical, 6)
            }.disabled(!app.canConfigure).accessibilityIdentifier("model.\(id.rawValue)")
        }.navigationTitle("四组内置模型").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var app: SoundController
    var body: some View {
        Form {
            Section("模型") {
                NavigationLink { ModelPickerView() } label: { LabeledContent("当前模型", value: app.model.title) }
                Text("四组模型随应用安装，离线切换，一次只加载一组。").font(.caption).foregroundStyle(.secondary)
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
                if app.model == .yamnet { LabeledContent("原生窗口", value: "0.975 s · 15,600 samples") }
                else { Stepper("分析窗口：\(app.options.windowSeconds.formatted()) s", value: $app.options.windowSeconds, in: 1...30, step: 1) }
                Picker("步长", selection: $app.options.stepSeconds) {
                    ForEach((app.model == .yamnet ? [0.24, 0.48, 0.975] : [0.5, 1, 2, 5, 10]).filter { $0 <= app.options.windowSeconds }, id: \.self) { Text("\($0.formatted()) s").tag($0) }
                }
                Stepper("同类合并间隔：\(app.options.mergeGapSeconds.formatted()) s", value: $app.options.mergeGapSeconds, in: 0...5, step: 0.25)
                Stepper("CPU线程：\(app.options.threads)", value: $app.options.threads, in: 1...4)
                Text("窗口影响短声稀释和首次等待。尾窗补零并保留有效音频范围；不使用语音VAD。更小步长会增加计算量。").font(.caption).foregroundStyle(.secondary)
                Button("应用设置") { app.applySettings() }
                Button("恢复当前模型默认值") { app.restoreDefaults() }
            }
            Section("类别阈值") {
                Toggle("启用门铃、警报等扩展提示", isOn: $app.options.includeExtensions)
                ForEach(TargetCategory.all.filter { $0.primary || app.options.includeExtensions }) { target in
                    VStack(alignment: .leading) {
                        HStack { Text(target.chinese); Spacer(); Text(scoreText(app.options.thresholds[target.id])).monospacedDigit() }
                        Slider(value: Binding(get: { app.options.thresholds[target.id] ?? 0.3 }, set: { app.options.thresholds[target.id] = $0 }), in: 0...1, step: 0.01)
                    }
                }
                Text("0.30仅为观察起点，未校准。各类独立判断，支持重叠；通用冲击声不代表确认有人跌倒。").font(.caption).foregroundStyle(.secondary)
            }
            Section("文件与版本") {
                Text("权重与类别表随App内置；加载前核对字节数及SHA256。替换模型需更新清单后重新构建。")
                LabeledContent("SoundTest", value: "1.0.0")
                LabeledContent("中文显示映射", value: ChineseLabels.version)
                LabeledContent("模型输入", value: "16 kHz · 单声道 Float32")
                Text("模型分数、音频时长、推理耗时均保留原始口径。系统声音分类器及EfficientAT尚未加入本版。")
            }
        }.disabled(!app.canConfigure).navigationTitle("设置")
        .onChange(of: app.options.windowSeconds) { _, value in if app.options.stepSeconds > value { app.options.stepSeconds = value } }
    }
}

struct HistoryView: View {
    @EnvironmentObject private var app: SoundController
    var body: some View {
        List {
            Section("内置模型信息") {
                ForEach(app.assets) { asset in NavigationLink { ModelInfoView(asset: asset) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(SoundModelID(rawValue: asset.id)?.title ?? asset.id)
                        Text("\(app.availableModels.contains(SoundModelID(rawValue: asset.id) ?? .zipformer) ? "内置文件完整" : "文件缺失或大小不符") · \(ByteCountFormatter.string(fromByteCount: asset.bytes, countStyle: .file))").font(.caption).foregroundStyle(.secondary)
                    }
                } }
            }
            Section("历史测试 · \(app.history.count)") {
                if app.history.isEmpty { Text("完成一次测试后会自动保存记录。").foregroundStyle(.secondary) }
                ForEach(app.history) { record in NavigationLink { LoadRecordView(id: record.id) } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("\(record.material.testCase) · \(record.model.title)").font(.headline)
                        Text(record.material.filename ?? record.material.inputMethod.rawValue).lineLimit(1)
                        Text("\(record.startedAt.formatted(date: .numeric, time: .shortened)) · \(timeText(record.audioSeconds)) · \(record.status)").font(.caption).foregroundStyle(.secondary)
                    }
                }.swipeActions { Button("删除", role: .destructive) { app.delete(record) } } }
            }
        }.navigationTitle("日志及模型信息").refreshable { app.reloadHistory() }
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
                Text("多标签片段分类；连续模式由应用分窗。时间边界是估计，非模型原生SED输出。").font(.caption)
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
                LabeledContent("模型", value: record.model.title)
                LabeledContent("时间", value: record.startedAt.formatted())
                LabeledContent("状态", value: record.status)
                LabeledContent("设备", value: record.device)
                LabeledContent("实际输入", value: record.actualInput)
                LabeledContent("输入方式", value: record.material.inputMethod.rawValue)
                LabeledContent("测试编号", value: record.material.testCase)
                LabeledContent("样本编号", value: record.material.sampleID)
                LabeledContent("文件", value: record.material.filename ?? "麦克风未保存文件")
                LabeledContent("人工标签", value: record.material.manualLabel)
                LabeledContent("来源 / 许可", value: "\(record.material.source) · \(record.material.permission)")
                LabeledContent("模式", value: record.options.mode.rawValue)
                LabeledContent("窗口 / 步长", value: "\(record.options.windowSeconds) / \(record.options.stepSeconds) s")
                LabeledContent("合并间隔", value: timeText(record.options.mergeGapSeconds))
                ForEach(TargetCategory.all) { target in LabeledContent(target.chinese + "阈值", value: scoreText(record.options.thresholds[target.id])) }
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
            Text(window.targets.filter(\.prompted).map(\.chinese).joined(separator: "、").isEmpty ? "未提示目标类别" : window.targets.filter(\.prompted).map(\.chinese).joined(separator: "、")).font(.caption).foregroundStyle(.secondary)
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
            Section("Top-5") { ForEach(window.top5) { ScoreRow(score: $0) } }
            Section("重点与扩展类别") { ForEach(window.targets) { TargetRow(target: $0) } }
            Section { NavigationLink("全部 \(window.scores.count) 类原始分数") { AllScoresView(scores: window.scores) } }
        }.navigationTitle("窗口 #\(window.index + 1)").navigationBarTitleDisplayMode(.inline)
    }
}
struct ScoreRow: View {
    let score: RawScore
    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) { Text(ChineseLabels.name(score.label)); Text(score.label).font(.caption).foregroundStyle(.secondary) }
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
            VStack(alignment: .trailing, spacing: 3) { Text(scoreText(target.score)).monospacedDigit(); Text(target.prompted ? "达到提示阈值" : (target.enabled ? "未提示" : "仅观察")).font(.caption).foregroundStyle(target.prompted ? .blue : .secondary) }
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

import SwiftUI

struct WatchContentView: View {
    @State private var selectedPage = 0

    var body: some View {
        TabView(selection: $selectedPage) {
            WatchModelPage().tag(0)
            WatchLivePage().tag(1)
            WatchLogsPage().tag(2)
            WatchSettingsPage().tag(3)
        }
        .tabViewStyle(.page(indexDisplayMode: .always))
    }
}

private struct WatchModelPage: View {
    @EnvironmentObject private var sound: WatchSoundController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("模型")
                    .font(.headline)
                Text("只有已在手表本地接入的模型可以选择。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                ForEach(WatchModelChoice.all) { model in
                    Button {
                        sound.setModel(model.id)
                    } label: {
                        HStack(alignment: .top, spacing: 7) {
                            Image(systemName: model.id == sound.selectedModelID ? "checkmark.circle.fill" : (model.available ? "circle" : "minus.circle"))
                                .foregroundStyle(model.id == sound.selectedModelID ? .green : .secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(model.name)
                                    .font(.caption)
                                    .fontWeight(model.available ? .semibold : .regular)
                                Text(model.detail)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .disabled(!model.available || sound.isRecording)
                    .padding(.vertical, 6)
                    .accessibilityIdentifier("watchModel_\(model.id)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
        }
    }
}

private struct WatchLivePage: View {
    @EnvironmentObject private var sound: WatchSoundController

    private var latestPrompt: String {
        guard let window = sound.latestWindow else { return "等待音频分析" }
        let names = window.targets.filter(\.prompted).map(\.name)
        return names.isEmpty ? "暂无目标提示" : names.joined(separator: "、")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("实时测试")
                    .font(.headline)
                Text("\(sound.selectedModelName) · 手表本地")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Text(latestPrompt)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(sound.latestWindow?.targets.contains(where: \.prompted) == true ? .green : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("watchLiveResult")

                if sound.isRecording || sound.isStopping {
                    Text(String(format: "已采集 %.0f 秒", sound.elapsedSeconds))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let inferenceMS = sound.currentInferenceMS {
                    Text(String(format: "本轮推理调用累计 %.0f ms", inferenceMS))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Button {
                    if sound.isRecording { sound.stop() } else { sound.start() }
                } label: {
                    Label(sound.isRecording ? "停止并保存" : sound.isStarting ? "启动中" : "开始识别",
                          systemImage: sound.isRecording ? "stop.fill" : "mic.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(sound.isRecording ? .red : .blue)
                .disabled(sound.isStarting || sound.isStopping)
                .accessibilityIdentifier("watchRecordButton")

                if let window = sound.latestWindow {
                    Text(String(format: "窗口 %d · %.2f–%.2f 秒", window.index, window.start, window.end))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Divider()
                    Text("目标分数")
                        .font(.caption.weight(.semibold))
                    ForEach(window.targets, id: \.name) { target in
                        HStack(spacing: 4) {
                            Text(target.name)
                            Spacer(minLength: 2)
                            Text(target.score.map { String(format: "%.3f", $0) } ?? "—")
                                .monospacedDigit()
                        }
                        .font(.caption2)
                    }
                    Text("原始 Top 5")
                        .font(.caption.weight(.semibold))
                        .padding(.top, 3)
                    ForEach(Array(window.scores.sorted { $0.score > $1.score }.prefix(5).enumerated()), id: \.offset) { _, score in
                        HStack(spacing: 4) {
                            Text(score.label)
                                .lineLimit(1)
                            Spacer(minLength: 2)
                            Text(String(format: "%.3f", score.score))
                                .monospacedDigit()
                        }
                        .font(.caption2)
                    }
                }
                if let message = sound.message {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("分数是模型输出，不是识别准确率；窗口时间不等于精确事件边界。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
        }
    }
}

private struct WatchLogsPage: View {
    @EnvironmentObject private var sound: WatchSoundController

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 9) {
                    Text("手表日志")
                        .font(.headline)
                    Text("本机 \(sound.logs.count) 条")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Button {
                        sound.exportAllLogs()
                    } label: {
                        Label("导出并同步至 iPhone", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(sound.logs.isEmpty)
                    .accessibilityIdentifier("watchExportAllLogs")
                    Text(sound.transferMessage)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(sound.logs) { log in
                        NavigationLink {
                            WatchLogDetailPage(log: log)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(log.startedAt, format: .dateTime.month().day().hour().minute())
                                    .font(.caption.weight(.semibold))
                                Text(String(format: "%.1f 秒 · %d 窗", log.audioSeconds, log.windows.count))
                                    .font(.caption2)
                                Text(sound.status(for: log))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityIdentifier("watchLog_\(log.id)")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
            }
        }
    }
}

private struct WatchLogDetailPage: View {
    let log: WatchTestLog

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 7) {
                Text(log.modelName)
                    .font(.headline)
                Text(log.startedAt, format: .dateTime.year().month().day().hour().minute().second())
                    .font(.caption2)
                Text(String(format: "音频 %.2f 秒 · %d 窗", log.audioSeconds, log.windows.count))
                    .font(.caption2)
                Text(log.inferenceMS.map { String(format: "推理调用累计 %.1f ms", $0) } ?? "纯推理耗时未测")
                    .font(.caption2)
                Text("状态：\(log.status)")
                    .font(.caption2)
                if let error = log.error {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                ForEach(log.windows, id: \.index) { window in
                    Divider()
                    Text(String(format: "窗口 %d：%.2f–%.2f 秒", window.index, window.start, window.end))
                        .font(.caption.weight(.semibold))
                    let prompts = window.targets.filter(\.prompted).map(\.name)
                    Text(prompts.isEmpty ? "无目标提示" : prompts.joined(separator: "、"))
                        .font(.caption2)
                    ForEach(Array(window.scores.sorted { $0.score > $1.score }.prefix(3).enumerated()), id: \.offset) { _, score in
                        Text("\(score.label) · \(String(format: "%.3f", score.score))")
                            .font(.caption2)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
        }
    }
}

private struct WatchSettingsPage: View {
    @EnvironmentObject private var sound: WatchSoundController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("设置")
                    .font(.headline)
                Text(String(format: "提示阈值 %.2f", sound.threshold))
                    .font(.caption)
                Slider(value: $sound.threshold, in: 0.10...0.90, step: 0.05)
                    .disabled(sound.isRecording || sound.isStarting || sound.isStopping)
                    .accessibilityIdentifier("watchThreshold")
                Text("仅影响四类目标提示，不改动原始模型分数。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Toggle("新目标触感提醒", isOn: $sound.hapticsEnabled)
                    .font(.caption2)
                Divider()
                Text("输入：手表当前麦克风")
                    .font(.caption2)
                Text("仅在应用前台采集；离开前台会结束本轮并保存日志。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("纯本地分类。导出只传日志 JSON，不传原始音频。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("SoundTest Watch · 2.0.0")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
        }
    }
}

import SwiftUI

struct WatchLogsView: View {
    @EnvironmentObject private var inbox: WatchLogInbox

    var body: some View {
        List {
            Section("同步状态") {
                Text(inbox.connectionStatus)
                if let error = inbox.lastError { Text(error).foregroundStyle(.red) }
                Text("手表端点“导出并同步”后，文件会经配对连接异步传送。这里只显示 iPhone 已收到并保存的记录。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Apple Watch 记录 · \(inbox.logs.count)") {
                if inbox.logs.isEmpty {
                    ContentUnavailableView("暂无手表日志", systemImage: "applewatch",
                                           description: Text("在手表端完成测试，再到日志页导出。"))
                }
                ForEach(inbox.logs) { log in
                    NavigationLink {
                        WatchLogDetailView(log: log)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(log.modelName).font(.headline)
                            Text("\(log.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(String(format: "%.1f 秒", log.audioSeconds)) · \(log.windows.count) 窗")
                                .font(.caption).foregroundStyle(.secondary)
                            if let latest = log.windows.last,
                               let best = latest.targets.filter({ $0.prompted }).max(by: { ($0.score ?? 0) < ($1.score ?? 0) }) {
                                Text("最近提示：\(best.name)").font(.caption).foregroundStyle(.blue)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Apple Watch 日志")
        .refreshable { inbox.refresh() }
    }
}

private struct WatchLogDetailView: View {
    let log: WatchTestLog

    var body: some View {
        List {
            Section("本轮信息") {
                LabeledContent("模型", value: log.modelName)
                LabeledContent("时间", value: log.startedAt.formatted())
                LabeledContent("设备", value: log.device)
                LabeledContent("输入", value: log.input)
                LabeledContent("状态", value: log.status)
                LabeledContent("音频时长", value: String(format: "%.2f 秒", log.audioSeconds))
                LabeledContent("阈值", value: String(format: "%.2f", log.threshold))
                LabeledContent("推理耗时", value: log.inferenceMS.map { String(format: "%.1f ms", $0) } ?? "未测：系统接口未提供")
                if let error = log.error { Text(error).foregroundStyle(.red) }
            }
            Section("窗口结果 · \(log.windows.count)") {
                ForEach(log.windows) { window in
                    NavigationLink {
                        List {
                            Section("窗口范围（非精确事件边界）") {
                                Text(String(format: "%.2f–%.2f 秒", window.start, window.end))
                            }
                            Section("四个目标") {
                                ForEach(window.targets) { target in
                                    HStack {
                                        VStack(alignment: .leading) {
                                            Text(target.name)
                                            Text(target.label ?? "未返回对应标签").font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Text(target.score.map { String(format: "%.3f", $0) } ?? "—")
                                            .monospacedDigit()
                                    }
                                }
                            }
                            Section("原始分数") {
                                ForEach(window.scores.sorted { $0.score > $1.score }) { score in
                                    LabeledContent(score.label, value: String(format: "%.3f", score.score))
                                }
                            }
                        }.navigationTitle("窗口 #\(window.index + 1)")
                    } label: {
                        HStack {
                            Text(String(format: "#%d · %.1f–%.1f s", window.index + 1, window.start, window.end))
                            Spacer()
                            Text(window.targets.filter(\.prompted).map(\.name).joined(separator: "、"))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }
            if let url = WatchLogStore.url(for: log.id) {
                Section { ShareLink(item: url) { Label("分享完整手表 JSON", systemImage: "square.and.arrow.up") } }
            }
        }.navigationTitle("手表测试记录").navigationBarTitleDisplayMode(.inline)
    }
}

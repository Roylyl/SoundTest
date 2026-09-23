import SwiftUI
import UIKit

struct BatchImportPanel: View {
    @EnvironmentObject private var app: SoundController
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("批量测试 · \(app.batchFiles.count) 个文件", systemImage: "square.stack")
                    .font(.subheadline.bold())
                Spacer()
                Button("清空") { app.clearBatch() }.disabled(!app.canConfigure)
            }
            TextField("本轮名称（可选）", text: $app.batchName)
                .textFieldStyle(.roundedBorder).disabled(!app.canConfigure)
                .accessibilityIdentifier("batchName")
            if let group = app.activeBatchGroup {
                Text("\(group.model.title) · \(group.status.rawValue)").font(.caption).foregroundStyle(.secondary)
                ProgressView(value: Double(group.finishedCount), total: Double(group.items.count))
                Text("\(group.finishedCount)/\(group.items.count) · \(group.summary)")
                    .font(.caption.monospacedDigit()).accessibilityIdentifier("batchProgress")
                NavigationLink("查看本轮日志组") { BatchGroupDetail(id: group.id) }
            }
            NavigationLink { BatchQueueView() } label: {
                Label("查看文件列表", systemImage: "list.bullet")
            }
            if app.batchActive {
                Text(app.status).font(.caption).foregroundStyle(.secondary)
                Button("停止本轮", systemImage: "stop.fill") { app.stop() }
                    .soundButton().tint(.red).disabled(app.finishing)
            } else {
                Button(app.activeBatchGroup == nil ? "开始本轮测试" : "再测一轮", systemImage: "play.fill") { app.analyzeBatch() }
                    .soundButton(prominent: true).disabled(!app.ready || !app.canConfigure)
                    .accessibilityIdentifier("startBatch")
            }
            Text("按文件名顺序，使用当前模型逐个分析；每轮单独分组。切换模型后可复用列表再测，单个文件失败会继续下一项。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct BatchQueueView: View {
    @EnvironmentObject private var app: SoundController
    var body: some View {
        List {
            Section {
                Text("共 \(app.batchFiles.count) 个 WAV · 每个文件最多10分钟。一次只解码并分析一个文件。")
                Text("文件已临时复制到本机，可在当前 App 会话内切换模型重测。清空、替换列表或结束进程后，重新导入即可再次测试。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("文件顺序") {
                ForEach(Array(app.batchFiles.enumerated()), id: \.element.id) { index, file in
                    VStack(alignment: .leading, spacing: 5) {
                        Text("\(index + 1). \(file.filename)")
                        if let item = app.activeBatchGroup?.items.first(where: { $0.id == file.id }) {
                            Text(item.status.rawValue).font(.caption).foregroundStyle(item.status == .failed ? .red : .secondary)
                            if let error = item.error { Text(error).font(.caption).foregroundStyle(.red) }
                        } else if let error = file.importError {
                            Text("导入失败：\(error)").font(.caption).foregroundStyle(.red)
                        } else { Text("待分析").font(.caption).foregroundStyle(.secondary) }
                    }.padding(.vertical, 3)
                }
            }
        }.navigationTitle("批量文件").navigationBarTitleDisplayMode(.inline)
    }
}

struct BatchGroupRow: View {
    let group: BatchLogGroup
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "folder").foregroundStyle(.blue).padding(.top, 3)
            VStack(alignment: .leading, spacing: 5) {
                Text(group.name).font(.headline)
                Text("\(group.model.title) · \(group.items.count) 个文件").font(.subheadline)
                Text("\(group.status.rawValue) · \(group.summary)").font(.caption).foregroundStyle(.secondary)
                Text(group.startedAt.formatted(date: .numeric, time: .shortened)).font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 4)
    }
}

struct BatchGroupDetail: View {
    let id: String
    @EnvironmentObject private var app: SoundController
    @State private var exporting = false
    @State private var exported: BatchShareFile?
    private var group: BatchLogGroup? { app.batchHistory.first { $0.id == id } }
    var body: some View {
        Group {
            if let group {
                List {
                    Section("本轮") {
                        Text(group.name).font(.headline)
                        LabeledContent("模型", value: group.model.title)
                        LabeledContent("输入", value: "本地 WAV 批量导入")
                        LabeledContent("开始时间", value: group.startedAt.formatted())
                        LabeledContent("状态", value: group.status.rawValue)
                        Text(group.summary).font(.subheadline)
                        if let reason = group.stopReason { Text(reason).font(.caption).foregroundStyle(.secondary) }
                        LabeledContent("模式", value: group.options.mode.rawValue)
                        LabeledContent("窗口 / 步长", value: "\(group.options.windowSeconds.formatted()) / \(group.options.stepSeconds.formatted()) s")
                        LabeledContent("已读取音频合计", value: timeText(group.audioSeconds))
                        LabeledContent("推理调用合计", value: msText(group.inferenceMS))
                        Text("成功表示文件分析完成，不代表类别识别正确。原始分数、事件提示和异常保留在每份文件的记录里。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Section("文件结果 · \(group.items.count)") {
                        ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                            if let recordID = item.recordID, item.status.isTerminal {
                                NavigationLink { LoadRecordView(id: recordID) } label: { BatchItemRow(index: index, item: item) }
                            } else { BatchItemRow(index: index, item: item) }
                        }
                    }
                    Section {
                        Button { export() } label: {
                            if exporting { ProgressView("准备整组日志") }
                            else { Label("分享整组日志", systemImage: "square.and.arrow.up") }
                        }.disabled(exporting || group.status == .running || (app.batchActive && app.activeBatchGroup?.id == group.id)).accessibilityIdentifier("shareBatch")
                        Text("导出一个 JSON，包含本轮文件列表、各文件完整原始分数，以及失败和未运行项目。音频文件不包含在日志里。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                ContentUnavailableView("日志组不存在", systemImage: "folder.badge.questionmark", description: Text("该组可能已被删除，单条记录仍可从历史列表查看。"))
            }
        }.navigationTitle("批量日志组").navigationBarTitleDisplayMode(.inline)
        .sheet(item: $exported) { file in BatchShareSheet(url: file.url) }
    }
    private func export() {
        exporting = true
        Task {
            do { exported = BatchShareFile(url: try await Task.detached(priority: .userInitiated) { try BatchLogStore.export(id) }.value) }
            catch { app.errorMessage = error.localizedDescription }
            exporting = false
        }
    }
}

private struct BatchItemRow: View {
    let index: Int
    let item: BatchLogItem
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("\(index + 1). \(item.filename)").font(.subheadline)
            Text(item.status.rawValue).font(.caption).foregroundStyle(item.status == .failed ? .red : .secondary)
            if let seconds = item.audioSeconds {
                Text("\(timeText(seconds)) · 推理 \(item.inferenceMS.map(msText) ?? "未调用")")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let error = item.error { Text(error).font(.caption).foregroundStyle(.red) }
        }.padding(.vertical, 4)
    }
}

struct BatchShareFile: Identifiable {
    let id = UUID()
    let url: URL
}
struct BatchShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

import SwiftUI

struct TaskPicker: View {
    @EnvironmentObject private var app: SoundController
    var body: some View {
        Picker("识别任务", selection: Binding(get: { app.task }, set: { app.selectTask($0) })) {
            ForEach(SoundTask.allCases) { Text($0.rawValue).tag($0) }
        }.pickerStyle(.segmented).accessibilityIdentifier("taskPicker")
    }
}
struct SceneSettings: View {
    @EnvironmentObject private var app: SoundController
    private func value<T>(_ path: WritableKeyPath<SceneOptions,T>) -> Binding<T> {
        Binding(get: { (app.options.scene ?? SceneOptions())[keyPath:path] }, set: { new in
            var options = app.options.scene ?? SceneOptions(); options[keyPath:path] = new; app.options.scene = options
        })
    }
    var body: some View {
        Section("场景平滑") {
            Stepper("平均最近 \((app.options.scene ?? SceneOptions()).averagingWindows) 窗", value: value(\.averagingWindows), in: 1...10)
            Stepper("连续确认 \((app.options.scene ?? SceneOptions()).confirmationWindows) 窗", value: value(\.confirmationWindows), in: 1...5)
            LabeledContent("最低候选分数", value: thresholdText((app.options.scene ?? SceneOptions()).minimumScore))
            Slider(value: value(\.minimumScore), in: 0...1, step: 0.01)
            LabeledContent("前两名最低差值", value: thresholdText((app.options.scene ?? SceneOptions()).minimumMargin))
            Slider(value: value(\.minimumMargin), in: 0...1, step: 0.01)
            Text("默认3窗平均、2窗确认。分数不足或候选接近时显示不确定；参数为观察起点，不是校准置信度。改变设置后用于下一轮。").font(.caption)
            Text(SceneAnalysis.coverage).font(.caption)
        }
    }
}
struct SceneResultView: View {
    let windows: [WindowResult]
    private var changes: [WindowResult] {
        var previous: String?, result: [WindowResult] = []
        for window in windows {
            guard let scene = window.scene else { continue }
            let key = scene.label ?? scene.state
            if key != previous { result.append(window); previous = key }
        }
        return Array(result.suffix(30))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("当前场景").font(.headline)
            Text(windows.last?.scene?.title ?? "判断中").font(.title2.bold())
            Text(SceneAnalysis.coverage).font(.caption).foregroundStyle(.secondary)
            if let last = windows.last, let scene = last.scene {
                Text("本窗原始候选 Top-3").font(.headline)
                ForEach(Array(last.top5.prefix(3))) { ScoreRow(score: $0) }
                if !scene.smoothedScores.isEmpty {
                    Text("平滑候选 Top-3 · 最近\(scene.averagingCount)窗").font(.headline)
                    ForEach(Array(scene.smoothedScores.sorted { $0.score > $1.score }.prefix(3))) { ScoreRow(score: $0) }
                }
                Text("分数为十个已知类别内的softmax输出，不是准确率；不确定规则不能可靠排除所有未知场景。").font(.caption).foregroundStyle(.secondary)
            }
            if !changes.isEmpty {
                Divider()
                Text("场景变化时间线").font(.headline)
                ForEach(changes) { window in
                    HStack(alignment: .top) {
                        Text(timeText(window.end)).monospacedDigit()
                        Text(window.scene?.title ?? "判断中")
                        if let label = window.scene?.label { Text(label).foregroundStyle(.secondary) }
                    }.font(.caption)
                }
                Text("时间为判定可用时的音频位置；包含窗口及平滑等待，不代表真实环境切换边界。首页仅保留最近80窗，完整记录可在日志查看。").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(18).background(.background, in: RoundedRectangle(cornerRadius: 22))
    }
}
enum SceneTestCases {
    static let all = [SoundTestCase(id:"C01",name:"已覆盖场景"), SoundTestCase(id:"C02",name:"未覆盖场景"), SoundTestCase(id:"C03",name:"场景切换"), SoundTestCase(id:"C04",name:"背景干扰"), SoundTestCase(id:"C05",name:"离线及事件回归")]
}

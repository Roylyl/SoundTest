import Foundation

enum SoundTask: String, Codable, CaseIterable, Identifiable {
    case events = "声音事件", scenes = "环境场景"
    var id: String { rawValue }
}
struct SceneOptions: Codable, Equatable, Sendable {
    var averagingWindows = 3
    var confirmationWindows = 2
    var minimumScore = 0.4
    var minimumMargin = 0.1
    var valid: Bool { (1...10).contains(averagingWindows) && (1...5).contains(confirmationWindows) && minimumScore.isFinite && (0...1).contains(minimumScore) && minimumMargin.isFinite && (0...1).contains(minimumMargin) }
}
struct ScenePrediction: Codable, Sendable {
    let rawScores: [RawScore]
    let smoothedScores: [RawScore]
    let state: String
    let label: String?
    let decisionAudioTime: Double
    let averagingStart: Double
    let averagingEnd: Double
    let averagingCount: Int
    var title: String { label.map(SceneAnalysis.name) ?? state }
}
struct SceneSmoother {
    private var history: [(Double, [RawScore])] = []
    private var candidate: String?
    private var count = 0
    mutating func update(scores: [RawScore], start: Double, end: Double, padded: Bool, options: SceneOptions) -> ScenePrediction {
        // An incomplete final second stays visible as raw output but does not create a scene decision.
        if padded { return ScenePrediction(rawScores: scores, smoothedScores: [], state: "判断中", label: nil, decisionAudioTime: end, averagingStart: start, averagingEnd: end, averagingCount: 0) }
        history.append((start,scores)); if history.count > options.averagingWindows { history.removeFirst(history.count-options.averagingWindows) }
        let average = scores.map { score in RawScore(index: score.index, label: score.label, score: history.reduce(0) { total, entry in total + (entry.1.first { $0.label == score.label }?.score ?? 0) } / Double(history.count)) }
        let ranked = average.sorted { $0.score > $1.score }
        var state = "判断中", label: String?
        if history.count >= options.averagingWindows, ranked.count >= 2 {
            if ranked[0].score < options.minimumScore || ranked[0].score-ranked[1].score < options.minimumMargin {
                state = "不确定"; candidate = nil; count = 0
            } else {
                let best = ranked[0].label
                if candidate == best { count += 1 } else { candidate = best; count = 1 }
                if count >= options.confirmationWindows { state = "已确认"; label = best }
            }
        }
        return ScenePrediction(rawScores: scores, smoothedScores: average, state: state, label: label,
            decisionAudioTime: end, averagingStart: history.first?.0 ?? start, averagingEnd: end, averagingCount: history.count)
    }
}
enum SceneAnalysis {
    static let labels = ["airport", "bus", "metro", "metro_station", "park", "public_square", "shopping_mall", "street_pedestrian", "street_traffic", "tram"]
    static let chinese = ["机场", "公交车内", "地铁车厢", "地铁站", "公园", "公共广场", "商场", "步行街", "交通街道", "有轨电车内"]
    static func name(_ label: String) -> String { labels.firstIndex(of: label).map { chinese[$0] } ?? label }
    static let coverage = "仅覆盖机场、公交车内、地铁车厢、地铁站、公园、公共广场、商场、步行街、交通街道、有轨电车内。居家、办公室等未覆盖；高分也不能证明属于已知环境。"
}
extension SoundModelID {
    var task: SoundTask { self == .cpMobile ? .scenes : .events }
    var sampleRate: Int { self == .cpMobile || self == .efficientAT ? 32000 : 16000 }
    static var eventModels: [SoundModelID] { allCases.filter { $0.task == .events } }
}

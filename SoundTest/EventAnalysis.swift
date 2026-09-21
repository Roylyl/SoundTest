import Foundation

enum EventAnalysis {
    static func targets(scores: [RawScore], options: SoundOptions) -> [TargetScore] {
        TargetCategory.all.map { target in
            let matching = scores.filter { target.labels.contains($0.label) }
            let best = matching.max { $0.score < $1.score }
            return TargetScore(id: target.id, chinese: target.chinese, score: best?.score,
                               originalLabel: best?.label, threshold: options.thresholds[target.id] ?? 0.3,
                               enabled: target.primary || options.includeExtensions)
        }
    }

    static func append(_ window: WindowResult, to events: inout [EventEstimate], options: SoundOptions) {
        let center = (window.start + window.end) / 2
        let start = max(window.start, center - options.stepSeconds / 2)
        let end = min(window.end, center + options.stepSeconds / 2)
        for target in window.targets where target.prompted {
            guard let score = target.score else { continue }
            if let last = events.lastIndex(where: { $0.categoryID == target.id }),
               start - events[last].estimatedEnd <= options.mergeGapSeconds + 0.000001 {
                events[last].evidenceEnd = max(events[last].evidenceEnd, window.end)
                events[last].estimatedEnd = max(events[last].estimatedEnd, end)
                events[last].peakScore = max(events[last].peakScore, score)
                events[last].windowIndices.append(window.index)
            } else {
                events.append(EventEstimate(categoryID: target.id, chinese: target.chinese,
                    evidenceStart: window.start, evidenceEnd: window.end,
                    estimatedStart: start, estimatedEnd: end, peakScore: score, windowIndices: [window.index]))
            }
        }
    }

    static func average(_ windows: [WindowResult]) -> [RawScore] {
        guard let first = windows.first else { return [] }
        let indexed = windows.map { Dictionary(uniqueKeysWithValues: $0.scores.map { ($0.index, $0) }) }
        return first.scores.compactMap { item in
            let values = indexed.compactMap { window -> Double? in
                guard let match = window[item.index], match.label == item.label else { return nil }
                return match.score
            }
            guard values.count == windows.count else { return nil }
            return RawScore(index: item.index, label: item.label, score: values.reduce(0, +) / Double(values.count))
        }
    }
}

/// Audio position planner shared by file and microphone runs. Tail inference covers only previously
/// uncovered audio, with zero padding explicitly represented; exact full windows get no extra tail.
struct WindowPlanner {
    let windowSamples: Int
    let stepSamples: Int
    private(set) var nextStart = 0
    private(set) var coveredEnd = 0
    init(options: SoundOptions, sampleRate: Int = 16000) {
        windowSamples = Int((options.windowSeconds * Double(sampleRate)).rounded())
        stepSamples = Int((options.stepSeconds * Double(sampleRate)).rounded())
    }
    mutating func next(total: Int, finishing: Bool) -> Range<Int>? {
        if nextStart + windowSamples <= total {
            let range = nextStart..<(nextStart + windowSamples)
            coveredEnd = range.upperBound; nextStart += stepSamples
            return range
        }
        if finishing && coveredEnd < total && nextStart < total {
            let range = nextStart..<total
            coveredEnd = total; nextStart = total
            return range
        }
        return nil
    }
}

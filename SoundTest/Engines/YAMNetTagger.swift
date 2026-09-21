import Foundation
import YAMNetRuntime

final class YAMNetTagger: TaggingEngine {
    private let runtime: YAMNetInterpreter
    private let labels: [String]

    init(modelURL: URL, labelsURL: URL, threads: Int = 2) throws {
        let text = try String(contentsOf: labelsURL, encoding: .utf8)
        let labels = text.split(whereSeparator: \.isNewline).map(String.init)
        guard labels.count == YAMNetInterpreter.classCount else {
            throw NSError(domain: "SoundTest.YAMNet", code: 1, userInfo: [NSLocalizedDescriptionKey: "YAMNet 配套类别表必须包含 521 行。"])
        }
        self.labels = labels
        self.runtime = try YAMNetInterpreter(modelURL: modelURL, threads: threads)
    }

    func classify(samples: [Float], sampleRate: Int) throws -> [RawScore] {
        try runtime.classify(samples: samples, sampleRate: sampleRate).enumerated().map {
            RawScore(index: $0.offset, label: labels[$0.offset], score: Double($0.element))
        }
    }
}

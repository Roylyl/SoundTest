import Accelerate
import CoreML
import Foundation

/// YAMNet's one-patch waveform frontend. The classifier accepts log-mel features,
/// so this step must run on the Watch before calling the local Core ML model.
/// See tensorflow/models/research/audioset/yamnet/features.py and params.py.
struct YAMNetWatchFeatures {
    static let sampleRate = 16_000
    static let sampleCount = 15_600
    static let frameCount = 96
    static let bandCount = 64

    private let dft: vDSP.DiscreteFourierTransform<Float>
    private let hann: [Float]
    private let melWeights: [Float]
    private let imaginaryInput = [Float](repeating: 0, count: 512)

    init() throws {
        dft = try vDSP.DiscreteFourierTransform(
            count: 512,
            direction: .forward,
            transformType: .complexComplex,
            ofType: Float.self
        )
        hann = (0..<400).map { n in
            0.5 - 0.5 * cos(2 * Float.pi * Float(n) / 400)
        }
        let lowMel = Self.mel(125)
        let highMel = Self.mel(7_500)
        var weights = [Float](repeating: 0, count: 257 * Self.bandCount)
        for bin in 1..<257 { // TensorFlow deliberately leaves the DC band at zero.
            let frequency = Float(bin) * Float(Self.sampleRate) / 512
            let mel = Self.mel(frequency)
            for band in 0..<Self.bandCount {
                let lower = lowMel + (highMel - lowMel) * Float(band) / 65
                let center = lowMel + (highMel - lowMel) * Float(band + 1) / 65
                let upper = lowMel + (highMel - lowMel) * Float(band + 2) / 65
                let left = (mel - lower) / (center - lower)
                let right = (upper - mel) / (upper - center)
                weights[bin * Self.bandCount + band] = max(0, min(left, right))
            }
        }
        melWeights = weights
    }

    /// Returns exactly one `[1,96,64]` Float16 Core ML input from 0.975 seconds
    /// of 16 kHz mono Float PCM. Resampling is intentionally the caller's task.
    func makeInput(samples: [Float]) throws -> MLMultiArray {
        guard samples.count == Self.sampleCount, samples.allSatisfy(\.isFinite) else {
            throw FeatureError.invalidWaveform
        }
        let features = try MLMultiArray(shape: [1, 96, 64], dataType: .float16)
        var realInput = [Float](repeating: 0, count: 512)
        var realOutput = [Float](repeating: 0, count: 512)
        var imaginaryOutput = [Float](repeating: 0, count: 512)
        var magnitudes = [Float](repeating: 0, count: 257)

        for frame in 0..<Self.frameCount {
            let offset = frame * 160
            for n in 0..<400 { realInput[n] = samples[offset + n] * hann[n] }
            dft.transform(
                inputReal: realInput,
                inputImaginary: imaginaryInput,
                outputReal: &realOutput,
                outputImaginary: &imaginaryOutput
            )
            for bin in 0..<257 {
                magnitudes[bin] = hypot(realOutput[bin], imaginaryOutput[bin])
            }
            for band in 0..<Self.bandCount {
                var melMagnitude: Float = 0
                for bin in 1..<257 {
                    melMagnitude += magnitudes[bin] * melWeights[bin * Self.bandCount + band]
                }
                features[frame * Self.bandCount + band] = NSNumber(value: log(melMagnitude + 0.001))
            }
        }
        return features
    }

    private static func mel(_ frequency: Float) -> Float {
        1127 * log(1 + frequency / 700)
    }

    enum FeatureError: Error {
        case invalidWaveform
    }
}

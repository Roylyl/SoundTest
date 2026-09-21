import Foundation
import TensorFlowLiteC

/// Runs the official MediaPipe YAMNet waveform model without altering its frontend.
/// Call only from a serial inference queue: a TFLite interpreter is not reentrant.
public final class YAMNetInterpreter {
    public static let sampleRate = 16_000
    public static let sampleCount = 15_600
    public static let classCount = 521
    public static let runtimeVersion = "TensorFlow Lite C 2.17.0"

    private let model: OpaquePointer
    private let interpreter: OpaquePointer

    public enum Failure: LocalizedError {
        case modelLoad, options, interpreter, allocate, incompatibleModel, invalidAudio, copyInput, invoke, copyOutput, invalidScores
        public var errorDescription: String? {
            switch self {
            case .modelLoad: return "无法读取 YAMNet 模型文件。"
            case .options: return "无法创建 TensorFlow Lite 运行设置。"
            case .interpreter: return "无法创建 YAMNet 本地推理器。"
            case .allocate: return "YAMNet 张量内存分配失败。"
            case .incompatibleModel: return "YAMNet 模型接口不匹配：要求 float32 输入 [15600]、输出 [1, 521]。"
            case .invalidAudio: return "YAMNet 需要 16 kHz 单声道、15600 个有限 Float32 样本；不足窗口须由上层明确补零并记录。"
            case .copyInput: return "YAMNet 音频写入失败。"
            case .invoke: return "YAMNet 本地推理失败。"
            case .copyOutput: return "YAMNet 分数读取失败。"
            case .invalidScores: return "YAMNet 返回了非有限数值或超出 [0, 1] 的分数。"
            }
        }
    }

    public init(modelURL: URL, threads: Int = 2) throws {
        guard let loadedModel = TfLiteModelCreateFromFile(modelURL.path) else { throw Failure.modelLoad }
        guard let options = TfLiteInterpreterOptionsCreate() else {
            TfLiteModelDelete(loadedModel)
            throw Failure.options
        }
        TfLiteInterpreterOptionsSetNumThreads(options, Int32(max(1, min(threads, 8))))
        let createdInterpreter = TfLiteInterpreterCreate(loadedModel, options)
        TfLiteInterpreterOptionsDelete(options)
        guard let createdInterpreter else {
            TfLiteModelDelete(loadedModel)
            throw Failure.interpreter
        }
        guard TfLiteInterpreterAllocateTensors(createdInterpreter) == kTfLiteOk else {
            TfLiteInterpreterDelete(createdInterpreter)
            TfLiteModelDelete(loadedModel)
            throw Failure.allocate
        }
        guard TfLiteInterpreterGetInputTensorCount(createdInterpreter) == 1,
              TfLiteInterpreterGetOutputTensorCount(createdInterpreter) == 1,
              let input = TfLiteInterpreterGetInputTensor(createdInterpreter, 0),
              let output = TfLiteInterpreterGetOutputTensor(createdInterpreter, 0),
              TfLiteTensorType(input) == kTfLiteFloat32,
              TfLiteTensorNumDims(input) == 1,
              TfLiteTensorDim(input, 0) == Self.sampleCount,
              TfLiteTensorByteSize(input) == Self.sampleCount * MemoryLayout<Float>.stride,
              TfLiteTensorType(output) == kTfLiteFloat32,
              TfLiteTensorNumDims(output) == 2,
              TfLiteTensorDim(output, 0) == 1,
              TfLiteTensorDim(output, 1) == Self.classCount,
              TfLiteTensorByteSize(output) == Self.classCount * MemoryLayout<Float>.stride else {
            TfLiteInterpreterDelete(createdInterpreter)
            TfLiteModelDelete(loadedModel)
            throw Failure.incompatibleModel
        }
        self.model = loadedModel
        self.interpreter = createdInterpreter
    }

    deinit {
        TfLiteInterpreterDelete(interpreter)
        TfLiteModelDelete(model)
    }

    /// Returns all class scores in the original model index order. No threshold, Top-K or VAD.
    public func classify(samples: [Float], sampleRate: Int) throws -> [Float] {
        guard sampleRate == Self.sampleRate,
              samples.count == Self.sampleCount,
              samples.allSatisfy({ $0.isFinite }) else { throw Failure.invalidAudio }
        guard let input = TfLiteInterpreterGetInputTensor(interpreter, 0) else { throw Failure.copyInput }
        let copyStatus = samples.withUnsafeBytes { bytes in
            TfLiteTensorCopyFromBuffer(input, bytes.baseAddress, bytes.count)
        }
        guard copyStatus == kTfLiteOk else { throw Failure.copyInput }
        guard TfLiteInterpreterInvoke(interpreter) == kTfLiteOk else { throw Failure.invoke }
        guard let output = TfLiteInterpreterGetOutputTensor(interpreter, 0) else { throw Failure.copyOutput }
        var scores = [Float](repeating: 0, count: Self.classCount)
        let resultStatus = scores.withUnsafeMutableBytes { bytes in
            TfLiteTensorCopyToBuffer(output, bytes.baseAddress, bytes.count)
        }
        guard resultStatus == kTfLiteOk else { throw Failure.copyOutput }
        guard scores.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }) else { throw Failure.invalidScores }
        return scores
    }
}

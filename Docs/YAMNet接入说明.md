# YAMNet 本地接入说明
核验日期：2026-09-21。模型来自 Google 官方 MediaPipe iOS Audio Classifier 示例的下载脚本。本工程使用同一份 TFLite 模型，通过 TensorFlow Lite C 2.17.0 在 CPU 本地运行；没有使用 MediaPipe Tasks 的录音与任务调度层。这样可以复用 SoundTest 的采集、分窗、计时和日志，并直接获得全部 521 个原始类别分数。
## 模型与文件
|项目|实际配置|
|---|---|
|模型|MediaPipe audio_classifier/yamnet/float32/1|
|权重文件|`ModelLibrary/yamnet/yamnet.tflite`，4,126,810 字节|
|类别表|模型附带的 `yamnet_label_list.txt` 原样提取，6,230 字节，521 行|
|模型许可|TFLite 内嵌元数据明确标注 Apache License 2.0；保留 LICENSE|
|运行库|本地 Swift Package `YAMNetRuntime`，TensorFlowLiteC 2.17.0 Core|
|输入|16,000 Hz 单声道 Float32 PCM，15,600 样本，名义幅度范围 −1 至 1|
|输出|Float32 `[1, 521]`，按原始类别索引保留全量分数|
|分析窗口|固定 0.975 秒；0.96 秒是特征块描述，不能用作本模型完整波形长度|
|内部精度|官方 URL 使用 `float32`，输入输出为 Float32；下载文件元数据明确说明内部为 8-bit 量化，不能将其描述为全浮点权重|
|架构|设备 arm64；模拟器 arm64 / x86_64|

来源、SHA-256、文件实际字节数分别保存在 `ModelLibrary/yamnet/YamnetManifest.json` 和 `Packages/YAMNetRuntime/RuntimeManifest.json`。只内置一份被调用的模型；未复制原 ASR 权重，也没有内置没用到的 TFLite CoreML、Metal delegate。
运行库上游框架切片缺少 `Info.plist`，本地为设备和模拟器切片各补充一个有效 plist，以通过 Xcode Swift Package 的 App 资源框架校验。上游二进制为静态可重定位 Mach-O 对象，本地未改动其内容；Xcode 处理静态框架与隐私资源时可能生成小型资源框架桩。新增 plist、各自 SHA-256 和修改后总字节数已记录在运行库清单。
## 调用与时间含义
`YAMNetTagger(modelURL:labelsURL:threads:)` 实现统一的 `TaggingEngine`。调用者必须提供 16 kHz、15,600 个样本；不满足时返回错误。采集重采样、短尾补零及其记录由上层统一处理，模型内部前处理保留在原始图中。
模型原有前处理使用 25 ms 窗、10 ms 帧移、周期 Hann 窗和 64 个 mel 频带。运行时直接传入波形，不再重复计算特征或归一化。输出为各类独立分数，不执行 softmax；没有阈值过滤、Top-K 裁剪或人声 VAD。中文显示映射由 App 处理，模型只接收波形，文件名与测试编号不进入推理。
连续分析对每个 0.975 秒窗口分别保存结果；步长由上层设置。阈值、合并间隔产生的是窗口分数推导的事件提示，不是模型输出的精确声学边界。整段结果可由上层对窗口分数求均值，短暂声音可能因均值被稀释，应同时看窗口结果和时间线。
## 已完成验证及边界
- 检查 TFLite 图：输入 Float32 `[15600]`，输出 Float32 `[1, 521]`，没有 custom op。
- Swift 包装层分别通过 iOS arm64 与 iOS Simulator arm64 的 Swift 类型检查。
- 在 iOS 27.0 arm64 模拟器上运行真实 TensorFlowLiteC 二进制和模型：全零窗口输出 521 个有限分数，最高类 `Silence`（索引 494）为 0.80078125。
- 同一模拟器对官方示例 `speech_16000_hz_mono.wav` 前 15,600 个样本运行真实推理：最高类 `Speech`（索引 0）为 0.91796875，全部 521 个分数在 [0, 1]。
- 检查模型标签与嵌入文件逐字节一致，标签未套用其他 AudioSet 模型的 527 类索引。

以上证明运行库与模型可以执行，不代表环境声识别准确率。猫狗叫声、咳嗽、笑声、鼓掌的实际表现，以及混合声音、输入切换、长期监听、真实延迟与发热，仍需使用统一用例在 iPhone 实测。模拟器烟雾验证源码位于 `Packages/YAMNetRuntime/Tools/smoke.c`；测试样本未打包到 App。
## 参考来源
官方 iOS 示例：https://github.com/google-ai-edge/mediapipe-samples/tree/main/examples/audio_classifier/ios
官方模型下载脚本：https://raw.githubusercontent.com/google-ai-edge/mediapipe-samples/main/examples/audio_classifier/ios/RunScripts/download_models.sh
官方模型文件：https://storage.googleapis.com/mediapipe-models/audio_classifier/yamnet/float32/1/yamnet.tflite
YAMNet 模型说明：https://github.com/tensorflow/models/tree/master/research/audioset/yamnet
TensorFlow Lite C 源码：https://github.com/tensorflow/tensorflow/tree/v2.17.0/tensorflow/lite/c
官方示例音频：https://storage.googleapis.com/mediapipe-assets/speech_16000_hz_mono.wav

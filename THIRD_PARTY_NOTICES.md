# 第三方来源与许可记录
核对日期：2026-09-23。本文对应 SoundTest iOS 内置的五组声音事件模型、一组环境场景模型、三个 iOS 推理运行库，以及配套 Watch App 的 Core ML YAMNet 权重。代码、模型权重、类别表和测试媒体分别记录；本文件不改变各资源的原有许可。
## 1. 工程代码与系统接口
SoundTest 参考同一作者的 ASRtest 工程及 README，复用、调整其后台音频会话、麦克风路由选择、采集提交屏障、SHA256 校验、计时和本地 JSON 日志处理方式。对应来源为 https://github.com/Roylyl/ASRtest 。SoundTest 使用新的模型接口和事件分析逻辑，没有复制旧语音识别权重、whisper.cpp、Vosk 或 Nano 运行库。
SwiftUI、AVFoundation、CryptoKit、Charts、Core ML 与 Sound Analysis 等通过 Apple SDK 使用。配套 Watch App 调用 Apple Sound Analysis 系统分类器，不随项目提供 Apple 模型权重；它不是开源模型。
## 2. 已包含的运行库
|组件|固定版本与来源|保留的许可及本地变化|
|---|---|---|
|sherpa-onnx shared iOS|1.13.8；源码 `11afbd009a7f8c08f4bcf2fc1b265d0df4670fbf`；复用原 ASRtest 已解析的官方 XCFramework|Apache-2.0；保留 `Docs/SherpaLicenses/sherpa-onnx-Apache-2.0.txt`。库内容未修改，新增独立 `SherpaTagging` SPM 包和 Audio Tagging Swift 适配器。|
|ONNX Runtime shared iOS|1.28.2；分发仓库 `csukuangfj/onnxruntime-libs`，原 SPM 固定源码 `8ebc5ebf92190903c274a7621ba4c96a732335ec`|核心 MIT；保留 `Docs/SherpaLicenses/onnxruntime-MIT.txt` 和同版本 `onnxruntime-ThirdPartyNotices.txt`。只使用 iOS shared 包。|
|TensorFlow Lite C Core iOS|2.17.0；Google 发布的 TensorFlowLiteC 包，原始压缩包 SHA256 `9667b476015f136e5b332ce040e12822c4ac6d5c58947882ddc809cdff0fb99e`|TensorFlow Apache-2.0 及原附第三方告知；保留 `Packages/YAMNetRuntime/LICENSE`、原头文件告知和隐私清单。只保留 Core，未引入 CoreML / Metal delegate。为两个框架 slice 补充 Info.plist，原静态二进制字节未改。|

运行库中的第三方组件保留各自许可；这里的核心许可名称不将所有内部组件重新授权。ONNX Runtime ThirdPartyNotices 是上游版本告知，不能据此认定所列组件全部进入当前 iOS 二进制。当前保存的文件与修改内容可按以下清单核对：
- `Docs/SherpaRuntimeFiles.json`：sherpa 和 ONNX Runtime XCFramework 逐文件大小、SHA256。
- `Packages/YAMNetRuntime/RuntimeManifest.json`：Google 压缩包来源、原始二进制 SHA256、补充 plist 及实际大小。
固定源码和发布地址：
- https://github.com/k2-fsa/sherpa-onnx/tree/11afbd009a7f8c08f4bcf2fc1b265d0df4670fbf
- https://github.com/k2-fsa/sherpa-onnx/releases/download/xcframework/sherpa-onnx-v1.13.8-ios-shared.xcframework.zip
- https://github.com/csukuangfj/onnxruntime-libs/tree/8ebc5ebf92190903c274a7621ba4c96a732335ec
- https://github.com/csukuangfj/onnxruntime-libs/releases/download/v1.28.2/onnxruntime-ios-shared-xcframework-1.28.2.xcframework.zip
- https://github.com/tensorflow/tensorflow/tree/v2.17.0/tensorflow/lite
- https://dl.google.com/tflite-release/ios/prod/tensorflow/lite/release/ios/release/32/20240729-115310/TensorFlowLiteC/2.17.0/0c10b3543e01f547/TensorFlowLiteC-2.17.0.tar.gz
## 3. 五组声音事件模型权重与类别表
|模型|当前文件版本|已核对的许可依据|
|---|---|---|
|Zipformer-small Audio Tagging INT8|k2-fsa / 2024-04-15；`c24f9d0fdf7d0b8c0c4f9733aa0cac51fda10c95`|固定下载仓库 README 直接声明 `license: apache-2.0`，原文件保留在模型目录。|
|CED-Tiny INT8|k2-fsa / 2024-04-19；`efe3a5cfad74e56598d855d055006903adc00e38`|作者 `mispeech/ced-tiny` 权重卡声明 Apache-2.0；k2 转换仓库 README 未单列许可，保留两者出处及原权重卡快照。|
|CED-Mini INT8|k2-fsa / 2024-04-19；`4da6df50dc47b25f91074b5ef7df4c1cc0dd7d4d`|作者 `mispeech/ced-mini` 权重卡声明 Apache-2.0；转换仓库的许可记录边界与 Tiny 相同。|
|YAMNet|Google MediaPipe `audio_classifier/yamnet/float32/1`；模型 SHA256 `4d8b4a53282dc83ef04e3e7dbc4fbc98082e34e44ed798e16c3a0cdd4c584faf`|下载文件内嵌元数据声明 Apache License 2.0；保留 `ModelLibrary/yamnet/LICENSE`。固定版本路径及文件哈希共同标识本次模型。|
|EfficientAT `mn10_as`|官方发布权重 `mn10_as_mAP_471.pt`，源码固定提交 `a425fdce92572e602a1d5634799bd9f1f2efa806`；本地派生 `mn10-as.onnx` 的 SHA256 为 `4ca271b035e3194ff49717c9c62909913d566ed4f3a1ff365238c9fce21368c4`|仓库源码附 MIT 许可，保留 `ModelLibrary/efficientAT/LICENSE-EfficientAT.txt`。发布页提供权重，但未单列权重许可；转换结果的公开再分发条件仍须向权利人核实，不能直接套用本工程 Apache-2.0。|

CED 原始训练、推理及导出代码仓库 https://github.com/RicherMans/CED 的 LICENSE 是 GPL-3.0；该代码许可与作者权重卡的 Apache-2.0 声明是两条记录。本工程通过 sherpa C API 加载转换权重，未复制该仓库的 Python 训练或导出实现。当前两个 k2 转换仓库没有独立许可字段，其固定转换副本的依据来自已保留的原权重卡，不将缺失字段描述为转换作者另行确认的授权。
三组 sherpa 模型各自保留下载仓库附带的 527 类 CSV；YAMNet 的 521 行类别表从同一 TFLite 文件的附属文件原样提取。EfficientAT 使用上游仓库的 527 类 CSV；内容与本项目现有同名 527 类表的 SHA256 相同，但各模型仍独立保留其文件和来源。没有以某模型的数值索引替换另一模型类别表。中文名称为 SoundTest 显示映射 `soundtest-zh-v1`，保留原始名称和分数，映射不改动模型文件或预测结果。
只内置实际调用的权重、类别表和前处理资源。每个必要文件的来源、实际字节数和 SHA256 在根目录 `ModelsManifest.json`；更详细的来源记录在 `Docs/SherpaModelFiles.json`、`ModelLibrary/yamnet/YamnetManifest.json` 和 `ModelLibrary/efficientAT/README.md`。EfficientAT 的原始 `.pt` 不打进 App。
EfficientAT 的 `mel-bank.f32` 与 `hann-window.f32` 按固定上游 `models/preprocess.py` 的评估参数离线生成，随 ONNX 和类别表接受相同的文件校验；它们不是 YAMNet 或 sherpa-onnx 的前处理资源。
模型与许可来源：
- https://huggingface.co/k2-fsa/sherpa-onnx-zipformer-small-audio-tagging-2024-04-15/blob/c24f9d0fdf7d0b8c0c4f9733aa0cac51fda10c95/README.md
- https://huggingface.co/k2-fsa/sherpa-onnx-ced-tiny-audio-tagging-2024-04-19/tree/efe3a5cfad74e56598d855d055006903adc00e38
- https://huggingface.co/k2-fsa/sherpa-onnx-ced-mini-audio-tagging-2024-04-19/tree/4da6df50dc47b25f91074b5ef7df4c1cc0dd7d4d
- https://huggingface.co/mispeech/ced-tiny/blob/ace276d29dd0bb3f3517b0fa8cf300738c409019/README.md
- https://huggingface.co/mispeech/ced-mini/blob/26c3ebcae85d4330f4fc26763f029539a3afcda0/README.md
- https://storage.googleapis.com/mediapipe-models/audio_classifier/yamnet/float32/1/yamnet.tflite
- https://github.com/fschmid56/EfficientAT/tree/a425fdce92572e602a1d5634799bd9f1f2efa806
- https://github.com/fschmid56/EfficientAT/releases/download/v0.0.1/mn10_as_mAP_471.pt
### Watch 端 YAMNet Core ML 权重
`SoundTestWatch/Resources/YAMNet.mlpackage` 来自社区发布的 https://huggingface.co/Yehor/YAMNet-CoreML/tree/9681162a6618cceb548ee2a94e83bcfb3a141066 ，固定提交 `9681162a6618cceb548ee2a94e83bcfb3a141066`。该模型卡将其标为 Apache-2.0，并说明权重由 TensorFlow Hub YAMNet SavedModel 转换而来，Core ML 包只接受 `[1,96,64]` Float16 log-mel 特征，不直接接受原始音频。权重文件 `Data/com.apple.CoreML/weights/weight.bin` SHA256 为 `39aee5b5261a4d27cab29a0cd0d272a8d949d456e551bb68c14182cafb78a8ea`。这是独立的社区转换件，不是 Google 官方 MediaPipe TFLite 文件；两者不得混称同一二进制。Apache-2.0 许可文本保存在 `Docs/Licenses/YAMNet-CoreML-Apache-2.0.txt`，并随 Watch App 打包为 `YAMNet-CoreML-LICENSE.txt`。
Watch 端 521 行 `yamnet_label_list.txt` 从本工程 iOS YAMNet 模型附属资源复制，SHA256 `8e1267a120c1932b7273c0d0e0c5529edbb9a35512b437b1c8982baa59047051`；与 Core ML 输出顺序通过标签索引和样例对照核验。手表端 16 kHz 音频到 log-mel 的前处理由本工程 Swift/Accelerate 实现，没有复制社区仓库的 Python 转换脚本。相同五段测试 WAV 上，Core ML 路线与 Google TensorFlow YAMNet 的 Top-1 类别一致，521 类分数平均绝对差为 `1.06e-5` 至 `4.99e-5`；这只是 Mac 上的数值一致性检查，不代表 Watch 真机速度或准确率已测。
## 4. 测试材料与用户数据
本工程参考项目调研资料和《SoundTest_声音识别测试记录.md》确定范围与用例编号，没有据此获得或假定其中提到的第三方录音授权。素材编号、文件名、来源、使用条件及人工标签属于测试记录，不进入预测接口。
开发时的 sherpa `test_wavs/12.wav` 狗叫样例和 Google `speech_16000_hz_mono.wav` 仅用于本机推理验证，未随 App 打包。没有将 AudioSet、ESC-50 或研究报告中提到的数据集作为 App 内置音频集。用户导入、主动保存和分享的片段仍按其各自来源记录管理。
`Tests/Unit/Fixtures` 另外保留五段 ESC-50 功能检查 WAV，以及自主生成的 EfficientAT 数值核对音频和特征数据；仅加入 XCTest 测试目标，不进入生产 App。数据集固定提交为 `33c8ce9eb2cf0b1c2f8bcf322eb349b6be34dbb6`；上游整体采用 CC BY-NC 3.0、ESC-10 子集采用 CC BY 3.0，同时保留各条原始录音署名与条款。测试媒体不适用模型或工程代码的 Apache-2.0 声明，其中非商业用途条件仍按原条款适用。

|测试文件|原作者与原录音|上游记录的原始录音许可|
|---|---|---|
|1-34094-A-5.wav|sazman；070422-cats-sample.wav|CC-BY；本条不属于 ESC-10，数据集副本按 ESC-50 整体 CC BY-NC 3.0 处理|
|1-100032-A-0.wav|nfrae；rose_bark.wav|CC0；本条属于 ESC-10 子集|
|1-19111-A-24.wav|Fratz；cough1.aiff|CC-BY|
|1-1791-A-26.wav|nicStage；stevenClayLaughLoop.wav|CC-BY|
|1-104089-A-22.wav|sorohanro；Clapping Small Room.wav|CC-BY|

逐条原始录音链接、下载地址与 SHA256 见 `Tests/Unit/Fixtures/EnvironmentFixtures.json`；完整许可在同目录 `ESC50-LICENSE.txt`，选样方法与范围在 README。对应上游许可：https://github.com/karolpiczak/ESC-50/blob/33c8ce9eb2cf0b1c2f8bcf322eb349b6be34dbb6/LICENSE 。该五段素材用来检查模型执行和输出格式，未用于训练或根据分数选择模型。
录音默认在内存处理；主动保存片段才写入本机 Samples 目录。JSON 分享操作由用户发起，内容含所选素材注释和识别记录；需要分享录音时另行选择已保存音频。
## 5. 参考项目与未接入模型
Google MediaPipe iOS Audio Classifier 示例用于核对 YAMNet 模型、标签和接口。实际预测通过 TensorFlow Lite C 完成，未包含 MediaPipe Tasks 的录音或任务调度库。
EfficientAT `mn10_as` 已按第 3 节的来源接入，使用现有 ONNX Runtime 和工程自写的 Accelerate 前处理；没有复制 EfficientAT 仓库的 Python 训练和推理源码。`mn04_as` 与 PANNs DecisionLevel 未打包。Apple Sound Analysis 仅由 Watch App 调用系统框架，未随 App 提供 Apple 权重。现有转换方法和验证边界见 `ModelLibrary/efficientAT/README.md`、`Docs/YAMNet与EfficientAT后续评估.md` 与 `Docs/AppleWatch集成与验证.md`。

## 6. CP-Mobile 环境场景模型与参考样例
来源：https://github.com/CPJKU/dcase2025_task1_inference ，固定提交 `da99d532999c8148cf3e0c7e0f9782324c04071e`。训练/设备适配参考：https://github.com/CPJKU/dcase2025_task1_baseline ，固定提交 `87a5f8c4957b00055f83f6f69af8c52b1a3bb405`。
使用 `Schmid_CPJKU_task1/ckpts/baseline.ckpt` 中的通用 base_model；提取、导出为本地 `ModelLibrary/cpMobile/cp-mobile.onnx`，同时导出配套标签。保留半精度源权重/特征的舍入，网络改用Float32计算；具体差异和验证见 `Docs/ASC/集成与验证.md`，哈希见 `ASCManifest.json`。
核对上述固定版本时，两仓库均未提供明确的LICENSE文件或代码/权重许可声明。此处记录来源不等于获得再分发授权；本轮仅完成用户本地研究集成，公开发布或商业分发前需向权利人确认代码、checkpoint和转换权重的使用条件。SoundTest根目录Apache-2.0不覆盖这些资源。本轮没有上传。
`Tests/Unit/Fixtures/asc-reference.f32` 来自同一推理仓库的 `Schmid_CPJKU_task1/resources/dummy.wav`，仅下混并重采样为32 kHz Float32，用于转换一致性检查；原资源未找到独立许可，按同样边界处理，不进入生产App。其JSON保存参考输出与PCM哈希，不表示素材有真实场景标注或模型准确率已验证。`Research/` 为本机复现用克隆，已加入gitignore。

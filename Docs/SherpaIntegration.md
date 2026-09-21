# sherpa-onnx 声音分类接入说明
核对与验证日期：2026-09-21。此目录记录 SoundTest 的三组 Audio Tagging 模型，与原 ASRtest 中的中英 Zipformer ASR 模型无关。
## 资源与运行库
|模型|固定模型版本|仅 INT8 权重实际字节数|
|---|---|---:|
|Zipformer-small|c24f9d0fdf7d0b8c0c4f9733aa0cac51fda10c95|27,038,066|
|CED-Tiny|efe3a5cfad74e56598d855d055006903adc00e38|6,133,417|
|CED-Mini|4da6df50dc47b25f91074b5ef7df4c1cc0dd7d4d|10,451,715|

每组保留其下载仓库配套的 `class_labels_indices.csv`（14,675 字节）和 README。当前三份类别表内容一致、各含 527 类；仍按模型配对存放。逐文件来源、固定 revision、实际字节数与 SHA256 在 `SherpaModelFiles.json`。没有复制浮点模型、ASR 权重或示例媒体进入 App 资源。
运行库复用原 ASRtest 已缓存的官方 shared XCFramework：sherpa-onnx 1.13.8（源码 11afbd009a7f8c08f4bcf2fc1b265d0df4670fbf）和 ONNX Runtime 1.28.2。仅 iOS 真机与模拟器 slice 保存在 `Packages/SherpaTagging`，原 ASRtest 未修改。两个 XCFramework 全文件共 112,602,236 字节，包含不同架构，不能当作安装到单台 iPhone 的大小。校验清单为 `SherpaRuntimeFiles.json`。
SPM 本地依赖为 `Packages/SherpaTagging`，product 为 `SherpaTagging`，不需要在线解析包。系统链接项为 C++ 和 Accelerate。动态库由 Xcode 随产品嵌入签名；不引入 whisper.cpp、Vosk 等 ASR 库。
上游发布包来源及上游 SPM 声明的压缩包 SHA256：
- https://github.com/k2-fsa/sherpa-onnx/releases/download/xcframework/sherpa-onnx-v1.13.8-ios-shared.xcframework.zip — 449fd0d139ef1efc11f8a202cd47bd6cff448ada1ba289210946bc3f2d65a689
- https://github.com/csukuangfj/onnxruntime-libs/releases/download/v1.28.2/onnxruntime-ios-shared-xcframework-1.28.2.xcframework.zip — d955b44322de53cc0be60e4939c89e46c2ba9dc0e9eef7f25ec8c73427ac6546
以上压缩包校验值来自原固定 SPM 配置；本次复用解压后的缓存，实际文件另作哈希，不把它们混为本次重新下载验证。
## 调用与前处理
`SherpaTagger(modelID:modelURL:labelsURL:threads:)` 实现统一 `TaggingEngine`。在后台串行分析队列创建/调用/释放；每次窗口创建独立 OfflineStream，而同一模型的权重跨窗口保持加载。切换模型时释放原实例。模型载入前由 App 完成文件大小和哈希校验，防止损坏文件进入原生模型加载器。
调用链为 CreateAudioTagging → AudioTaggingCreateOfflineStream → AcceptWaveformOffline → AudioTaggingCompute(top_k:527) → FreeResults / DestroyOfflineStream。每次必须返回 527 个有效且不重复的类别索引、与配套 CSV 一致的原始标签和有限分数，否则将窗口报告为异常，不能填零补齐。结果按类别索引保存；Top-5 排序只用于界面显示。没有模型分数后校准，也没有人声 VAD。
输入为 Float32、单声道 PCM。App 默认统一到 16 kHz；C API 同时接受实际采样率并在需要时内部重采样。不要把所有模型视为同一种前处理：在固定 sherpa 1.13.8 中，Zipformer 使用 16 kHz、80 维特征；CED 路径使用 16 kHz、64 维 filterbank、32 ms Hann 窗，关闭预加重、dither 和去直流，再执行相应幅度到 dB 变换。特征计算均交给模型配套 sherpa 实现。
建议默认 10 秒分析窗；App 的 sherpa 最短输入策略为 1 秒，并验证了 1、2、5、10、30 秒输入可运行。较短窗的模型效果需要真实素材比较。分窗提供的是分类窗口分数，不能产生真实、精确的事件起止标注。若最后不足 1 秒，由上层明确记录补零量或跳过原因。
## 验证范围
已运行 `SherpaSmoke.c`，经 `simctl spawn` 在本机已启动的 iPhone 18 Pro / iOS 27.0 模拟器直接加载该 iOS shared 动态库，库报告版本为 sherpa 1.13.8 / ONNX Runtime 1.28.2。每组完成 1、2、5、10、30 秒合成全零 PCM 和上游狗叫样例，18 次调用全部返回 527 个不重复、有限分数。原始输出见 `SherpaSmokeResults.txt`；其耗时是该模拟器/主机环境中 AcceptWaveform + Compute 的耗时，不是 iPhone 性能数据，也不是 App 界面提示延迟。
狗叫样例为以下固定地址的 `test_wavs/12.wav`，音频时长约 8.975 秒；三个模型的 Top-5 中均有 Bark，分数分别为 0.603950、0.511369、0.587781。这只验证真实模型链路和标签输出，不代表准确率。Zipformer 对某些全零长窗也会返回 Music 较高分，已保留该现象，没有改分数或添加静音捷径。
样例仅下载到本机临时路径 `/tmp/soundtest-sherpa-dog.wav`，未随 App 分发；校验值 a33d53dea1624b7411b4d88d9e3d5a4a632b6a6deb522ac3049643043545ee6b。
https://huggingface.co/k2-fsa/sherpa-onnx-zipformer-small-audio-tagging-2024-04-15/resolve/c24f9d0fdf7d0b8c0c4f9733aa0cac51fda10c95/test_wavs/12.wav
Swift 适配层已对 iOS 模拟器 SDK 完成类型检查。仍需要真机检查：实际麦克风路由、持续收音、设备性能与热量、系统中断、模型切换内存释放，以及 S01–S08 和顺序/重叠/边界样本效果。这里的模拟器验证不能代替这些项目。
## 使用条件与出处
sherpa-onnx 为 Apache-2.0，ONNX Runtime 核心为 MIT；原许可和 ONNX Runtime 上游 ThirdPartyNotices 已放在 `SherpaLicenses`。这些上游文件并非本工程对每个二进制内部组件的独立审计证明。
Zipformer 下载仓库固定 README 直接声明 Apache-2.0。CED 需要区分源码和权重：RicherMans/CED 训练/导出代码仓库 LICENSE 为 GPL-3.0，本工程没有复制或执行该 Python 代码；作者发布的 mispeech/ced-tiny、mispeech/ced-mini 权重卡声明 Apache-2.0。k2-fsa 的两个转换仓库 README 没有独立 license 字段，所以本工程保留转换来源和原权重卡，按上游权重声明记录，不将 CED 代码许可证改写为 Apache，也不宣称转换仓库已单独明确重新授权。向外发布带权重的产品前，应确认固定转换副本对应的授权范围及实际运行库依赖告知。
原权重卡快照：
- https://huggingface.co/mispeech/ced-tiny/blob/ace276d29dd0bb3f3517b0fa8cf300738c409019/README.md
- https://huggingface.co/mispeech/ced-mini/blob/26c3ebcae85d4330f4fc26763f029539a3afcda0/README.md
技术依据：
- https://k2-fsa.github.io/sherpa/onnx/audio-tagging/index.html
- https://k2-fsa.github.io/sherpa/onnx/audio-tagging/pretrained_models.html
- https://github.com/k2-fsa/sherpa-onnx/blob/11afbd009a7f8c08f4bcf2fc1b265d0df4670fbf/sherpa-onnx/c-api/c-api.h
- https://github.com/k2-fsa/sherpa-onnx/blob/11afbd009a7f8c08f4bcf2fc1b265d0df4670fbf/sherpa-onnx/csrc/offline-stream.cc
- https://github.com/RicherMans/CED

# EfficientAT mn10_as 接入与 YAMNet 对照
核对日期：2026-09-23。SoundTest 1.0.0 已把 EfficientAT `mn10_as` 作为 M05 接入本地模型列表。官方 PyTorch 权重转换为固定10秒输入的 ONNX，iOS 通过现有 ONNX Runtime 1.28.2 CPU 与 Accelerate 前处理执行。M05 不使用云端推理；`mn04_as` 尚未接入。
## 模型与接入状态
|项目|M04 YAMNet|M05 EfficientAT mn10_as|
|---|---|---|
|工程文件|TFLite；模型及类别表约4.13 MB|ONNX、类别表与前处理资源约19.80 MB，未量化|
|模型输入|16 kHz 单声道，0.975秒窗口|32 kHz 单声道，固定10秒窗口；本地128维 Mel 前处理|
|模型输出|521类逐窗分数|527类逐窗 sigmoid 分数|
|本地运行库|TensorFlow Lite C 2.17.0 CPU|ONNX Runtime 1.28.2 CPU，Accelerate 前处理|
|当前验证|500 份 WAV：来源目标命中 362/500|同一 500 份 WAV：来源目标命中 307/500；合成音频前处理与输出数值对齐|
两者的输入采样率、窗口、类别表和前处理都不同。当前 App 对 M05 的短音频补足10秒，对长音频分窗；它仍是片段分类模型，事件时间由应用窗口和阈值估计。模型分数之间不能直接比较大小，推理调用次数也受步长影响。
## 转换与数值核对
上游代码固定为 https://github.com/fschmid56/EfficientAT/tree/a425fdce92572e602a1d5634799bd9f1f2efa806 ，权重取自官方发布的 https://github.com/fschmid56/EfficientAT/releases/download/v0.0.1/mn10_as_mAP_471.pt 。原权重 SHA256 为 `0bd7dc2443af498c289a2e739f02ebb515d6aa3fd3ab9db539c86123ae368a4e`；派生 ONNX SHA256 为 `4ca271b035e3194ff49717c9c62909913d566ed4f3a1ff365238c9fce21368c4`。类别表和前处理文件各自的大小与哈希见 `ModelLibrary/efficientAT/README.md` 和 `ModelsManifest.json`。
ONNX 只包含分类网络及 sigmoid，输入 `[1,1,128,1000]`、输出 `[1,527]`。前处理在 iOS 本地执行：0.97预加重、1024点FFT、800点对称Hann窗、320点hop、反射填充、128维Kaldi Mel、对数及归一化。官方示例音频的 PyTorch 与 ONNX 全量分数最大绝对差 `4.77e-7`。自主生成的10秒测试音频在 iOS 模拟器上的 Mel 与 PyTorch 参考最大绝对差 `6.68e-6`，同时得到527个有限输出分数。这些数字验证实现对齐，不代表四个目标类的识别效果。
## 已验证范围
Xcode 27.1 的 iOS 模拟器构建已通过，合成音频的实际 iOS 前处理测试已通过；五组各 100 份 WAV 的批测完成，M05 的 500 条 Session 与 5 个批次日志均无异常。上述命中数只针对来源目标和统一 0.30 阈值，原始 JSON 与完整口径见 `SoundTest_声音识别测试记录.md`。本文件不据此推断真机速度或准确率。iPhone 真机的麦克风链路、内存峰值、耗电、温升与长时间监听尚未验证。尤其不能从 ONNX 文件约19.5 MB 推出运行内存。
## 许可边界
上游仓库源码附 MIT 许可，`ModelLibrary/efficientAT/LICENSE-EfficientAT.txt` 保留原文。官方发布页未给权重单列许可；本地派生 ONNX 的公开再分发条件须单独核对。SoundTest 的 Apache-2.0 不自动覆盖官方权重及其派生文件；详见 `THIRD_PARTY_NOTICES.md`。

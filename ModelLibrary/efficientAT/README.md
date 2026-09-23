# EfficientAT mn10_as（SoundTest M05）
SoundTest 1.0.0 使用 EfficientAT 官方 `mn10_as_mAP_471.pt` 权重生成固定 10 秒输入的 ONNX。模型只在本机运行，经 ONNX Runtime 1.28.2 CPU 推理；音频前处理由工程中的 Accelerate 代码完成。此目录没有打包原始 PyTorch 权重或 EfficientAT 训练代码。
## 来源与许可
- 上游源码：https://github.com/fschmid56/EfficientAT/tree/a425fdce92572e602a1d5634799bd9f1f2efa806
- 官方权重：https://github.com/fschmid56/EfficientAT/releases/download/v0.0.1/mn10_as_mAP_471.pt
- 原始权重 SHA256：`0bd7dc2443af498c289a2e739f02ebb515d6aa3fd3ab9db539c86123ae368a4e`
- 类别表：https://github.com/fschmid56/EfficientAT/blob/a425fdce92572e602a1d5634799bd9f1f2efa806/metadata/class_labels_indices.csv
- 上游源码附 MIT 许可，原文见本目录 `LICENSE-EfficientAT.txt`。官方发布页提供权重，但没有单列权重许可声明。本地 ONNX 由该权重转换而来；公开再分发转换权重前须核实其授权，SoundTest 根目录的 Apache-2.0 不自动覆盖它。
## 本地文件
|文件|字节|SHA256|用途|
|---|---:|---|---|
|`mn10-as.onnx`|19,515,407|`4ca271b035e3194ff49717c9c62909913d566ed4f3a1ff365238c9fce21368c4`|固定输入分类网络，ONNX opset 17|
|`class_labels_indices.csv`|14,675|`cdd1049833c4b86127c2773ac0d14a2754b6a6d0d1798002ed5c66e699708429`|上游527类索引和标签|
|`mel-bank.f32`|262,656|`e2024f719d9122b0876e8a3410e586a40e74ee9b62f402635fe2024b0433a49d`|128×513 的 Float32 Kaldi Mel 权重|
|`hann-window.f32`|3,200|`0c0d22798aa76bff12404eaa251c650b00751a2f6ac90783a7aaae2635531b1c`|800点对称 Hann 窗|
|`LICENSE-EfficientAT.txt`|1,071|`7a45b1641304427db80df436cab61c04ddb634d97e9a8b7a93de41db940fa8b5`|上游 MIT 许可原文|
前四项是本地推理必要文件，合计 **19,795,938 字节（19.80 MB）**；另有许可文本 1,071 字节。App 加载时按 `ModelsManifest.json` 检查文件大小和 SHA256。
## 转换与输入
工程在 `../../Scripts/EfficientAT/⟧ 保留了转换脚本、依赖说明和数值校验报告；脚本会先核验上游提交与原始权重 SHA-256。
导出使用上游固定提交的模型结构及官方发布权重，仅把分类网络和最后的 sigmoid 放入 ONNX。输入为 Float32 `[1,1,128,1000]`，输出为 Float32 `[1,527]`。输出已经是逐类 sigmoid 分数，App 不再重复执行 sigmoid；原始分数和原始标签都保存在日志中。本次转换使用 PyTorch 2.5.1、ONNX 1.17.0 和 ONNX Runtime 1.20.1；App 实际推理使用 ONNX Runtime 1.28.2。
每个输入窗口是 32 kHz 单声道 320,000 样本。前处理按上游 `models/preprocess.py` 的评估设置执行：系数 0.97 的预加重；1024 点 FFT、800 点对称 Hann 窗、320 点 hop、反射填充居中 STFT；128 维 Kaldi Mel（0–15 kHz）；最后计算 `（log(Mel + 1e-5) + 4.5）/5`。这得到 128×1000 的模型输入。窗口不足 10 秒时由 SoundTest 补零，日志记录原音频有效范围与补零范围。连续模式按步长重复分析窗口；显示的事件时间是分窗估计，不是模型输出的精确边界。
## 已完成的数值核对与边界
- 官方示例音频的 527 类分数：原始 PyTorch 与导出的固定 ONNX 最大绝对差 `4.77e-7`，平均绝对差 `2.55e-8`。这是模型转换一致性检查，不是识别准确率。
- 自主生成的 10 秒测试音频：iOS 模拟器实际前处理与 PyTorch 参考的 128,000 个 Mel 值最大绝对差 `6.68e-6`，并取得 527 个有限输出分数。该合成音频不代表猫狗叫声、咳嗽、笑声或鼓掌性能。
- 目前尚无 iPhone 真机对 M05 的麦克风采集、峰值内存、耗电、温升和连续监听结论。模拟器批量 WAV 的实测结果应以本项目测试记录及原始日志为准。
上游官方 `inference.py` 可按原始音频长度推理；SoundTest 当前固定为 10 秒输入，以便导出静态 ONNX 并记录分窗比较。模型参数量、ONNX 文件大小和 CPU 推理耗时是不同指标；这里的文件字节数不代表运行内存。

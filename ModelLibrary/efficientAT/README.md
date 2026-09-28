# EfficientAT mn10_as（SoundTest M05）
SoundTest 1.0.0使用EfficientAT官方 `mn10_as_mAP_471.pt` 权重生成固定10秒输入的ONNX。模型只在本机运行，经ONNX Runtime 1.28.2 CPU推理；音频前处理由工程中的Accelerate代码完成。此目录没有打包原始PyTorch权重或EfficientAT训练代码。
## 来源与许可
- 上游源码：https://github.com/fschmid56/EfficientAT/tree/a425fdce92572e602a1d5634799bd9f1f2efa806
- 官方权重：https://github.com/fschmid56/EfficientAT/releases/download/v0.0.1/mn10_as_mAP_471.pt
- 原始权重SHA256：`0bd7dc2443af498c289a2e739f02ebb515d6aa3fd3ab9db539c86123ae368a4e`
- 类别表：https://github.com/fschmid56/EfficientAT/blob/a425fdce92572e602a1d5634799bd9f1f2efa806/metadata/class_labels_indices.csv
- 上游源码附MIT许可，原文见本目录 `LICENSE-EfficientAT.txt`。官方发布页提供权重，但没有单列权重许可声明。本地ONNX由该权重转换而来；公开再分发转换权重前须核实其授权，SoundTest根目录的Apache-2.0不自动覆盖它。
## 本地文件
|文件|字节|SHA256|用途|
|---|---:|---|---|
|`mn10-as.onnx`|19,515,407|`4ca271b035e3194ff49717c9c62909913d566ed4f3a1ff365238c9fce21368c4`|固定输入分类网络，ONNX opset 17|
|`class_labels_indices.csv`|14,675|`cdd1049833c4b86127c2773ac0d14a2754b6a6d0d1798002ed5c66e699708429`|上游527类索引和标签|
|`mel-bank.f32`|262,656|`e2024f719d9122b0876e8a3410e586a40e74ee9b62f402635fe2024b0433a49d`|128×513的Float32 Kaldi Mel权重|
|`hann-window.f32`|3,200|`0c0d22798aa76bff12404eaa251c650b00751a2f6ac90783a7aaae2635531b1c`|800点对称Hann窗|
|`LICENSE-EfficientAT.txt`|1,071|`7a45b1641304427db80df436cab61c04ddb634d97e9a8b7a93de41db940fa8b5`|上游MIT许可原文|
前四项是本地推理必要文件，合计 **19,795,938字节（19.80 MB）**；另有许可文本1,071字节。App加载时按 `ModelsManifest.json` 检查文件大小和SHA256。
## 转换与输入
工程在 `../../Scripts/EfficientAT/⟧ 保留了转换脚本、依赖说明和数值校验报告；脚本会先核验上游提交与原始权重SHA-256。
导出使用上游固定提交的模型结构及官方发布权重，仅把分类网络和最后的sigmoid放入ONNX。输入为Float32 `[1,1,128,1000]`，输出为Float32 `[1,527]`。输出已经是逐类sigmoid分数，App不再重复执行sigmoid；原始分数和原始标签都保存在日志中。本次转换使用PyTorch 2.5.1、ONNX 1.17.0和ONNX Runtime 1.20.1；App实际推理使用ONNX Runtime 1.28.2。
每个输入窗口是32 kHz单声道320,000样本。前处理按上游 `models/preprocess.py` 的评估设置执行：系数0.97的预加重；1024点FFT、800点对称Hann窗、320点hop、反射填充居中STFT；128维Kaldi Mel（0–15 kHz）；最后计算 `（log(Mel + 1e-5) + 4.5）/5`。这得到128×1000的模型输入。窗口不足10秒时由SoundTest补零，日志记录原音频有效范围与补零范围。连续模式按步长重复分析窗口；显示的事件时间是分窗估计，不是模型输出的精确边界。
## 已完成的数值核对与边界
- 官方示例音频的527类分数：原始PyTorch与导出的固定ONNX最大绝对差 `4.77e-7`，平均绝对差 `2.55e-8`。这是模型转换一致性检查，不是识别准确率。
- 自主生成的10秒测试音频：iOS模拟器实际前处理与PyTorch参考的128,000个Mel值最大绝对差 `6.68e-6`，并取得527个有限输出分数。该合成音频不代表猫狗叫声、咳嗽、笑声或鼓掌性能。
- 目前尚无iPhone真机对M05的麦克风采集、峰值内存、耗电、温升和连续监听结论。模拟器批量WAV的实测结果应以本项目测试记录及原始日志为准。
上游官方 `inference.py` 可按原始音频长度推理；SoundTest当前固定为10秒输入，以便导出静态ONNX并记录分窗比较。模型参数量、ONNX文件大小和CPU推理耗时是不同指标；这里的文件字节数不代表运行内存。

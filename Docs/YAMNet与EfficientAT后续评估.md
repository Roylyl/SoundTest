# EfficientAT 后续接入评估
评估日期：2026-09-21。EfficientAT `mn04_as` 保留为下一轮候选，本轮没有将它声明为已安装或可推理，也未添加同名占位推理结果。首批四个模型的交付不依赖此转换。
## 结论
优先研究 `mn04_as`，必要时再用 `mn10_as` 比较质量与耗时。仓库提供 PyTorch 音频分类模型和权重，未核验到可直接放入本工程的官方 iOS 运行包；不能把模型文件改后缀视为移植完成。
官方表格中 `mn04_as` 为约 0.983M 参数，`mn10_as` 为约 4.88M 参数。参数量只描述网络规模，不能推导 iPhone 延迟、峰值内存或整个 App 体积。
## 前处理需要单独对齐
本次阅读了上游 `inference.py`、`models/preprocess.py` 和 README。默认推理是 32 kHz 单声道、128 个 mel 频带、窗长 800 样本、步长 320 样本和 1024 点 FFT。实现还包含 0.97 预加重、非周期 Hann 窗、居中 STFT、Kaldi mel filterbank、`log(melspec + 0.00001)` 与 `(melspec + 4.5) / 5`。推理必须使用 `eval()`，关闭训练时的数据增强；输出 logits 后还需要 sigmoid。
这些细节与 YAMNet 前处理不同，也不能默认等于 sherpa-onnx Audio Tagging 的前处理。Torch STFT 的 padding、mel filterbank、浮点精度和动态时间维度是转换时的主要核验项。
## 接入顺序
1. 固定 EfficientAT 源码提交、`mn04_as` 权重、类别表及许可，先在电脑 CPU 运行参考脚本，保留统一音频的全量分数。
2. 优先把分类网络导出为 ONNX，使用本工程已经依赖的 ONNX Runtime；前处理可保留为单独模块，但必须与 Python 逐项比较。若 ONNX 图含不支持的算子，再评估 Core ML，避免同时引入多余运行库。
3. 对静音、短片段、单目标、混合目标及不同长度音频，分别比较特征张量、全部类别输出、Top-5 和重点类分数；报告绝对误差及差异，不只看最高类别是否一致。
4. iPhone 验证加载、连续窗口、速度、内存、发热和后台/中断恢复。只有转换正确性与真机运行都经过核验后，才把模型加入可切换列表。
5. `mn04_as` 达到基本可运行状态后，再决定是否加入 `mn10_as`。仓库模型使用 MIT 许可声明；实际发布时保留源码许可与所选权重的来源和条款记录。
## 参考来源
仓库：https://github.com/fschmid56/EfficientAT
前处理：https://github.com/fschmid56/EfficientAT/blob/main/models/preprocess.py
推理入口：https://github.com/fschmid56/EfficientAT/blob/main/inference.py
许可：https://github.com/fschmid56/EfficientAT/blob/main/LICENSE

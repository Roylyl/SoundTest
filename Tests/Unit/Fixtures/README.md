# 环境声音功能检查素材
这五段 WAV 只属于 XCTest 测试目标，不随生产 App 安装，不参与模型训练或推理参数。它们分别对应猫叫、狗叫、咳嗽、笑声和鼓掌，用来检查真实音频解码、分窗、模型调用和原始分数输出；单个样本不能代表识别准确率、iPhone 麦克风效果或事件边界精度。
来源：ESC-50 固定提交 `33c8ce9eb2cf0b1c2f8bcf322eb349b6be34dbb6`。选择规则是在对应类别内按文件名排序取第一段，在执行模型之前确定，未按模型分数挑选。每段为上游提供的 5 秒、44.1 kHz、单声道 WAV，下载后未改写。
https://github.com/karolpiczak/ESC-50/tree/33c8ce9eb2cf0b1c2f8bcf322eb349b6be34dbb6
## 许可与署名
数据集整体采用 CC BY-NC 3.0；其中 ESC-10 子集采用 CC BY 3.0。原始录音还有各自的许可和署名，以下按上游 LICENSE 记录。音频不采用 SoundTest 源码许可证；使用和再分发须遵守原许可中的非商业用途等适用条件。完整上游声明保留在 `ESC50-LICENSE.txt`。
https://github.com/karolpiczak/ESC-50/blob/33c8ce9eb2cf0b1c2f8bcf322eb349b6be34dbb6/LICENSE
https://creativecommons.org/licenses/by-nc/3.0/
https://creativecommons.org/licenses/by/3.0/
|用例|ESC-50 文件|原始录音、作者|上游列明的原始片段许可|
|---|---|---|---|
|S01 猫叫|1-34094-A-5.wav|070422-cats-sample.wav，sazman|CC-BY；该条不属于 ESC-10，数据集副本按 ESC-50 整体 CC BY-NC 3.0 处理|
|S02 狗叫|1-100032-A-0.wav|rose_bark.wav，nfrae|CC0；该条为 ESC-10 子集|
|S03 咳嗽|1-19111-A-24.wav|cough1.aiff，Fratz|CC-BY|
|S04 笑声|1-1791-A-26.wav|stevenClayLaughLoop.wav，nicStage|CC-BY|
|S05 鼓掌|1-104089-A-22.wav|Clapping Small Room.wav，sorohanro|CC-BY|
原作者链接、下载地址、实际大小和 SHA-256 在 `EnvironmentFixtures.json` 中。S06 使用测试中生成的 5 秒数字静音，它不能替代真实安静环境录音。
## 检查方法
`EnvironmentSampleTests` 依次加载四个实际打包模型，以 App 的默认窗口、步长及 0.3 类别阈值分析同一批 PCM 音频，保存每窗完整原始分数、四个业务目标的聚合分数及事件提示。猫叫和狗叫是两条独立内容用例，但都映射到“猫狗叫声”业务目标。不足窗口的尾段显式补零并记录补零时长。标签和文件名只在结果中作比较说明，不传给模型。测试通过只表示解码及模型输出格式有效，不要求预期类别一定超过阈值，不将单例命中率宣传为准确率。
输出位于测试宿主 App 的 `Documents/environment-samples-verification.json`。其中的推理调用耗时来自当前运行环境；模拟器结果不能作为 iPhone 性能测量。

## ASC转换检查
asc-reference.f32是CPJKU推理仓库固定版本dummy.wav经下混和32 kHz重采样的1秒波形，仅用于转换一致性测试，不进入生产App。asc-reference.json记录对应ONNX输出与PCM哈希。该上游素材未提供明确许可，公开再分发前需确认授权；详见根目录THIRD_PARTY_NOTICES.md第6节。不是有标注的真实场景评测素材。

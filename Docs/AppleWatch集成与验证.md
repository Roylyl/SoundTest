# Apple Watch 配套 App：集成与验证
## 实现范围
`SoundTestWatch` 是与 iOS `SoundTest` 配套的独立 watchOS target，最低 watchOS 10，版本 1.0.0。四个页面左右滑动：模型、实时结果、日志、设置。测试在手表前台选择 Apple Sound Analysis 系统声音分类器或 YAMNet Core ML；麦克风音频在手表本地处理，不传给 iPhone 推理，也不上传网络。只把猫狗叫声、咳嗽、笑声和鼓掌作为业务目标；日志保留对应模型的原始英文标签及分数。分窗时间不是人工标注的事件边界，分数不是准确率。
## 模型边界
|Watch 选项|当前状态|原因|
|---|---|---|
|Apple Sound Analysis（系统模型）|可在 Watch target 中调用|watchOS 提供声音流分类 API；Apple 系统模型，不是开源权重。|
|YAMNet（Core ML）|可在 Watch target 中调用；真机性能待测|社区 Core ML 权重与工程内 Swift/Accelerate 前处理，16 kHz 单声道，每 0.975 秒一个不重叠窗口，521 类。|
|Zipformer-small、CED-Tiny、CED-Mini|不可选择|工程内 sherpa-onnx / ONNX Runtime 仅有 iOS 与 iOS Simulator 二进制。|
|EfficientAT mn10_as、CP-Mobile|不可选择|工程内 ONNX Runtime 仅有 iOS 与 iOS Simulator 二进制。|
这些状态只描述当前工程，不宣称上游模型本身永远不能转换或移植。系统模型和 YAMNet Core ML 分别记录，不能把 Apple 系统输出当作 YAMNet 或 CED 的结果。Watch YAMNet 使用 `SoundTestWatch/WatchYAMNetFeatures.swift` 与 `WatchYAMNetEngine.swift`；`Scripts/WatchConversion` 保留转换核对材料，不参与 App 编译。
Core ML 权重固定于 Yehor/YAMNet-CoreML 提交 `9681162a6618cceb548ee2a94e83bcfb3a141066`，权重文件 7,462,610 字节、SHA256 `39aee5b5261a4d27cab29a0cd0d272a8d949d456e551bb68c14182cafb78a8ea`，许可和来源见 `THIRD_PARTY_NOTICES.md`。Mac 上用五段实际 WAV 将完整路径与 TensorFlow YAMNet 对照，五段 Top-1 均相同，521 类分数平均绝对差为 `1.06e-5` 至 `4.99e-5`；逐文件音频哈希和数值见 `Scripts/WatchConversion/validation.json`。这验证了转换及前处理的数值一致性，不等于已测 Watch 真机性能或业务准确率。
## 日志同步
Watch 测试结束后在本机 `Documents/WatchLogs/<UUID>.json` 保存完整窗口记录。用户在手表日志页点击导出，应用将 JSON 通过 `WCSession.transferFile` 排队传给配对 iPhone。iPhone 先校验 schema、UUID、模型标识、大小和必要数值，再存入自己的独立 `Documents/WatchLogs`；入库后用 `transferUserInfo` 返回收据。Watch 界面把“已排队”“传送完成待确认”“iPhone 已接收”区分显示。iPhone 日志页底部的“查看 Apple Watch 上的日志”只显示已实际入库记录。iPhone 原有 `Documents/Sessions` 日志与清空动作不受影响。
传输是异步的；WatchConnectivity 不保证点导出后立即送达。需要在一对已配对且安装两个 App 的真机上核验送达、后台接收、重复传送去重和收据状态。Apple 官方说明模拟器不支持 `transferFile` 的完整验证。
## 构建与实测边界
工程使用 Xcode 27.1 和 watchOS 27 SDK。可分别检查 Watch 与 iOS 配套包：
```sh
xcodebuild -project SoundTest.xcodeproj -scheme SoundTestWatch -destination 'generic/platform=watchOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project SoundTest.xcodeproj -scheme SoundTest -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```
本机已完成通用 watchOS 与配套 iOS 包构建，Watch App 和 Core ML 资源已嵌入 iOS 包；iPhone 模拟器上的两项 Watch 日志导入单元测试和一项日志入口 UI 测试通过。本机没有可用的 watchOS Simulator runtime。检测到一只已配对的 `Watch6,7`（watchOS 26.6），但 Xcode 当前报告本地网络连接已断开，因此尚未在真表上完成麦克风、推理速度、内存、耗电或日志传送实测。通用构建成功只证明 API、类型和打包路径通过。
真表连通后，先在 Xcode 中以 `SoundTestWatch` Scheme 安装并授予麦克风权限，再分别选择 Apple Sound Analysis 与 YAMNet，录制短片段，确认实时窗口与停止后的完整日志。在手表日志页点击“导出并同步至 iPhone”，确认手表显示“iPhone 已接收”，并在 iPhone 日志页底部打开“查看 Apple Watch 上的日志”核对同一条 UUID、模型、窗口及分数。手表 App 在后台可能被系统挂起，因此当前实现只定位为前台测试，不承诺降腕后的连续监听。
## 依据
- Apple Sound Analysis 音频流分类：https://developer.apple.com/documentation/soundanalysis/classifying-sounds-in-an-audio-stream
- WatchConnectivity 文件传输：https://developer.apple.com/documentation/watchconnectivity/wcsession/transferfile%28_%3Ametadata%3A%29
- Apple Watch 扩展运行时间：https://developer.apple.com/documentation/watchkit/using-extended-runtime-sessions
- ONNX Runtime 平台构建说明：https://onnxruntime.ai/docs/build/ios.html
- Watch YAMNet Core ML 固定版本：https://huggingface.co/Yehor/YAMNet-CoreML/tree/9681162a6618cceb548ee2a94e83bcfb3a141066

# CP-Mobile 简化版（通用模型）
DCASE 2025 Task 1：CPJKU/dcase2025_task1_inference，固定提交 da99d532999c8148cf3e0c7e0f9782324c04071e。
来源：https://github.com/CPJKU/dcase2025_task1_inference
源checkpoint：Schmid_CPJKU_task1/ckpts/baseline.ckpt；仅选base_model（unknown设备），不含设备专属分支。
App使用cp-mobile.onnx和labels.txt，合计2,369,927字节；SHA256与固定来源见ASCManifest.json。其余说明文件不参与推理。
输入：Float32 [1,32000]，1秒32 kHz单声道。图内完成STFT、Mel与log，输出10类logits；App再计算softmax并独立做时间平滑。转换和验证详见../../Docs/ASC/集成与验证.md。
上游所核对版本未提供明确许可证，公开再分发前需取得相应授权；不属于SoundTest Apache-2.0授权范围。此包用于本机研究验证，未上传。

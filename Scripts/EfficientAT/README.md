# EfficientAT mn10_as export for SoundTest
This directory retains the conversion source and the numerical-verification report. It does not include a second copy of the upstream checkout, original PyTorch checkpoint, or test audio. The app uses `ModelLibrary/efficientAT/mn10-as.onnx⟧; this script is for independent regeneration and comparison.

To reproduce, use Python 3.12 and prepare the paths expected by the script:

```sh
cd Scripts/EfficientAT
git clone https://github.com/fschmid56/EfficientAT.git
git -C EfficientAT checkout a425fdce92572e602a1d5634799bd9f1f2efa806
mkdir -p assets
curl --fail --location https://github.com/fschmid56/EfficientAT/releases/download/v0.0.1/mn10_as_mAP_471.pt --output assets/mn10_as_mAP_471.pt
python3 -m venv .venv
.venv/bin/python -m pip install 'torch==2.5.1' 'torchvision==0.20.1' 'torchaudio==2.5.1' 'onnx==1.17.0' 'onnxruntime==1.20.1' 'numpy==1.26.4' 'scipy==1.14.1'
.venv/bin/python export_verify.py
shasum -a 256 assets/mn10_as_527_128mel.onnx
```

The script refuses a checkout or checkpoint with unexpected SHA/revision. Compare the resulting ONNX SHA-256 with `verification.json⟧ and the in-app manifest before replacing the bundled model. The upstream source license and checkpoint redistribution status are separate; see `../../THIRD_PARTY_NOTICES.md⟧.
Source: https://github.com/fschmid56/EfficientAT at commit `a425fdce92572e602a1d5634799bd9f1f2efa806`.
Official release asset: https://github.com/fschmid56/EfficientAT/releases/download/v0.0.1/mn10_as_mAP_471.pt (SHA-256 `0bd7dc2443af498c289a2e739f02ebb515d6aa3fd3ab9db539c86123ae368a4e`).
The repository carries the MIT license in `LICENSE-EfficientAT.txt`. The release description publishes pretrained weights but does not state a separate weight license.

The preferred ONNX artifact is `assets/mn10_as_527_128mel.onnx` (SHA-256 `4ca271b035e3194ff49717c9c62909913d566ed4f3a1ff365238c9fce21368c4`; 19,515,407 bytes). This is *network only*: float32 `[1,1,128,1000]` Mel-frequency log-power input; float32 `[1,527]` Sigmoid scores output; ONNX opset 17. Use a 10 s 32 kHz mono clip, with the official preprocessor producing exactly 1,000 frames. The Sigmoid is inside the ONNX graph, so do not apply it again. The 527 labels are the original CSV row order in `assets/class_labels_indices.csv`.

Official preprocessing settings from `models/preprocess.py`: preemphasis via convolution `[-0.97, 1.0]`, STFT `n_fft=1024`, `win_length=800`, `hop_length=320`, `center=True`, symmetric Hann (`periodic=False`), power spectrum, Kaldi mel banks (128 bins, low=0, high=15,000 Hz at 32 kHz), `log(mel + 1e-5)`, then `(value + 4.5)/5`. Evaluation mode disables frequency/time masking and random frequency bounds. The ONNX graph does *not* contain this preprocessing. Ensure a native iOS implementation agrees with `assets/reference_mel.npy` before trusting event scores.

A dynamic-time variant is also available at `assets/mn10_as_527_128mel_dynamic.onnx` (SHA-256 `603e6c05579c41121a503fba6b448badfd81490cb5563374b2e43cf766391071`). It passed 500- and 1,000-frame numerical parity tests, but the published AudioSet result used 10 s windows. Use the fixed model for first integration; changing duration changes the evaluation condition.

`verification.json` records exact shapes, software versions, checksums, PyTorch↔ONNX numerical differences, and the official sample WAV top labels. `export_verify.py` reproduces the export with a Python 3.12 environment containing torch 2.5.1, torchvision 0.20.1, torchaudio 2.5.1, onnx 1.17.0, onnxruntime 1.20.1, numpy 1.26.4, scipy 1.14.1. Run it from the official checkout (`cd EfficientAT && ../.venv/bin/python ../export_verify.py`).

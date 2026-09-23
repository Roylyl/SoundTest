"""Reproducible official EfficientAT mn10_as network-only ONNX export/parity check.
Run from official EfficientAT checkout with the isolated .venv.
"""
from __future__ import annotations
import csv
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import warnings

import numpy as np
import scipy.io.wavfile
import scipy.signal
import torch
import onnx
import onnxruntime as ort

ROOT = Path(__file__).resolve().parent
REPO = ROOT / 'EfficientAT'
sys.path.insert(0, str(REPO))
from models.mn.model import get_model
from models.preprocess import AugmentMelSTFT

ASSET = ROOT / 'assets' / 'mn10_as_mAP_471.pt'
OUT = ROOT / 'assets' / 'mn10_as_527_128mel.onnx'
OUT_DYN = ROOT / 'assets' / 'mn10_as_527_128mel_dynamic.onnx'
LABELS = REPO / 'metadata' / 'class_labels_indices.csv'
EXPECTED_COMMIT = 'a425fdce92572e602a1d5634799bd9f1f2efa806'
EXPECTED_WEIGHTS_SHA256 = '0bd7dc2443af498c289a2e739f02ebb515d6aa3fd3ab9db539c86123ae368a4e'

class Scores(torch.nn.Module):
    def __init__(self, core):
        super().__init__()
        self.core = core
    def forward(self, mel):
        logits, _ = self.core(mel)
        return torch.sigmoid(logits)

def sha(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for b in iter(lambda: f.read(1 << 20), b''):
            h.update(b)
    return h.hexdigest()

def audio_mel():
    sr, wave = scipy.io.wavfile.read(REPO / 'resources' / 'metro_station-paris.wav')
    if wave.dtype == np.int32:
        wave = wave.astype(np.float32) / 2**31
    elif wave.dtype == np.int16:
        wave = wave.astype(np.float32) / 2**15
    else:
        raise ValueError(f'Unexpected PCM type: {wave.dtype}')
    assert wave.ndim == 1 and sr == 44100
    wave = scipy.signal.resample_poly(wave, 320, 441).astype(np.float32)
    assert wave.shape == (320000,)
    frontend = AugmentMelSTFT(n_mels=128, sr=32000, win_length=800, hopsize=320)
    frontend.eval()
    with torch.no_grad():
        mel = frontend(torch.from_numpy(wave[None, :])).unsqueeze(0)
    assert mel.shape == (1, 1, 128, 1000), mel.shape
    np.save(ROOT / 'assets' / 'reference_mel.npy', mel.numpy())
    return mel

def check(session, wrapper, mel):
    with torch.no_grad():
        pt = wrapper(mel).numpy()
    pred = session.run(None, {'mel': mel.numpy()})[0]
    return {
        'shape': list(pred.shape),
        'max_abs_error': float(np.abs(pt - pred).max()),
        'mean_abs_error': float(np.abs(pt - pred).mean()),
        'max_relative_error_gt_1e_3': float((np.abs(pt - pred) / np.maximum(np.abs(pt), 1e-3)).max()),
        'torch_minmax': [float(pt.min()), float(pt.max())],
        'onnx_minmax': [float(pred.min()), float(pred.max())],
    }, pt, pred


def main():
    revision = subprocess.check_output(['git', '-C', str(REPO), 'rev-parse', 'HEAD'], text=True).strip()
    if revision != EXPECTED_COMMIT:
        raise RuntimeError(f'Expected upstream {EXPECTED_COMMIT}, found {revision}')
    if sha(ASSET) != EXPECTED_WEIGHTS_SHA256:
        raise RuntimeError('Official EfficientAT weight SHA-256 does not match')
    OUT.parent.mkdir(parents=True, exist_ok=True)
    torch.set_num_threads(2)
    torch.manual_seed(17)
    print('Constructing official architecture', flush=True)
    core = get_model(num_classes=527, pretrained_name=None, width_mult=1.0,
                     head_type='mlp', input_dim_f=128, input_dim_t=1000)
    print('Loading official state_dict', flush=True)
    state = torch.load(ASSET, map_location='cpu', weights_only=True)
    print('State entries:', len(state), flush=True)
    core.load_state_dict(state, strict=True)
    core.eval()
    model = Scores(core).eval()
    mel = audio_mel()
    with torch.no_grad():
        sample = model(mel)
    assert sample.shape == (1, 527), sample.shape
    options = {'input_names':['mel'], 'output_names':['scores'], 'opset_version':17,
               'do_constant_folding':True, 'export_params':True}
    print('Exporting fixed network', flush=True)
    with warnings.catch_warnings():
        warnings.simplefilter('ignore')
        torch.onnx.export(model, mel, OUT, **options)
    onnx.checker.check_model(str(OUT))
    sess = ort.InferenceSession(str(OUT), providers=['CPUExecutionProvider'])
    report = {'source_commit': revision,
              'official_weights_url': 'https://github.com/fschmid56/EfficientAT/releases/download/v0.0.1/mn10_as_mAP_471.pt',
              'weights_sha256': sha(ASSET), 'onnx_sha256': sha(OUT),
              'onnx_bytes': OUT.stat().st_size,
              'opset': 17, 'onnx_input_shape': sess.get_inputs()[0].shape,
              'onnx_output_shape': sess.get_outputs()[0].shape,
              'torch_version': torch.__version__, 'onnx_version': onnx.__version__,
              'onnxruntime_version': ort.__version__, 'tests': {}}
    report['tests']['official_metro_audio'] = check(sess, model, mel)[0]
    np.save(ROOT / 'assets' / 'reference_scores.npy', sample.numpy())
    synthetic = torch.from_numpy(np.random.default_rng(17).normal(0,1,(1,1,128,1000)).astype(np.float32))
    report['tests']['deterministic_random_mel'] = check(sess, model, synthetic)[0]
    print('Trying dynamic-time export', flush=True)
    try:
        with warnings.catch_warnings():
            warnings.simplefilter('ignore')
            torch.onnx.export(model, mel, OUT_DYN,
                              dynamic_axes={'mel': {3:'frames'}}, **options)
        onnx.checker.check_model(str(OUT_DYN))
        dsess = ort.InferenceSession(str(OUT_DYN), providers=['CPUExecutionProvider'])
        report['dynamic_time'] = {'input_shape': dsess.get_inputs()[0].shape,
                                  'onnx_sha256': sha(OUT_DYN), 'onnx_bytes': OUT_DYN.stat().st_size,
                                  'tests': {}}
        for n in (500,1000):
            spec = synthetic[:,:,:,:n].contiguous()
            report['dynamic_time']['tests'][str(n)] = check(dsess, model, spec)[0]
    except Exception as e:
        report['dynamic_time'] = {'error': repr(e)}
    with open(LABELS, newline='') as f:
        labels = list(csv.DictReader(f))
    report['labels_count'] = len(labels)
    report['labels_sha256'] = sha(LABELS)
    top = np.argsort(sample.numpy()[0])[::-1][:10]
    report['official_audio_top10'] = [(int(i), labels[i]['mid'], labels[i]['display_name'], float(sample.numpy()[0,i])) for i in top]
    result = ROOT / 'verification.json'
    result.write_text(json.dumps(report, indent=2, ensure_ascii=False)+'\n')
    print(json.dumps(report, indent=2, ensure_ascii=False), flush=True)

if __name__ == '__main__':
    main()

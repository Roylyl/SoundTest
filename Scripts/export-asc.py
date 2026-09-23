"""Reproduce CP-Mobile unknown-device export; run in pinned conversion environment."""
import sys,json,hashlib,copy,subprocess
from pathlib import Path
import numpy as np
import torch,torchaudio,onnx,onnxruntime as ort,soundfile as sf
root=Path(__file__).resolve().parents[1]
repo=root/'Research/dcase2025_task1_inference'
sys.path.insert(0,str(repo))
from Schmid_CPJKU_task1.Schmid_CPJKU_task1_1 import load_model,load_inputs,get_model_for_device
# The published checkpoint requires pickle loading. Verify the fixed upstream artifact first.
from Schmid_CPJKU_task1.Schmid_CPJKU_task1_1 import Baseline,Config
ckpt=repo/'Schmid_CPJKU_task1/ckpts/baseline.ckpt'
assert hashlib.sha256(ckpt.read_bytes()).hexdigest() == '399908d314b99e86b95c96edeea69de42710f23a7a0a53b2161931ed5f2425c8', 'Unexpected checkpoint; refusing pickle load'
baseline=Baseline(Config())
state=torch.load(ckpt,map_location='cpu',weights_only=False)['state_dict']
baseline.model.load_state_dict({k.replace('multi_device_model.',''):v for k,v in state.items() if k.startswith('multi_device_model.')},strict=True)
baseline.eval()
base=get_model_for_device(baseline,'unknown').eval()
assert base is baseline.model.base_model
class Export(torch.nn.Module):
 def __init__(self):
  super().__init__(); self.net=copy.deepcopy(base).float()
  self.register_buffer('window',torch.hann_window(3072))
  self.register_buffer('fb',baseline.mel.mel_scale.fb.clone())
 def forward(self,wave):
  stft=torch.stft(wave,n_fft=4096,hop_length=500,win_length=3072,window=self.window,center=True,pad_mode='reflect',normalized=False,onesided=True,return_complex=False)
  power=stft.square().sum(-1)
  mel=torch.matmul(power.transpose(-1,-2),self.fb).transpose(-1,-2)
  # Reference casts log-mel to half before its fp16 network. Preserve that rounding.
  features=(mel+1e-5).log().half().float().unsqueeze(1)
  return self.net(features)
model=Export().eval(); out=root/'ModelLibrary/cpMobile'; out.mkdir(exist_ok=True)
x=torch.zeros(1,32000)
with torch.no_grad():
 torch.onnx.export(model,x,str(out/'cp-mobile.onnx'),input_names=['waveform'],output_names=['logits'],opset_version=17,dynamo=False)
onnx.checker.check_model(onnx.load(str(out/'cp-mobile.onnx')))
session=ort.InferenceSession(str(out/'cp-mobile.onnx'),providers=['CPUExecutionProvider'])
# Reference repo's file and deterministic signal controls; no accuracy claim.
paths=[repo/'Schmid_CPJKU_task1/resources/dummy.wav', root/'Tests/Unit/Fixtures/1-34094-A-5.wav']
results=[];fixtures=[]
for path in paths:
 wave,sr=sf.read(path,dtype='float32',always_2d=True)
 mono=torch.from_numpy(wave.mean(1)).unsqueeze(0)
 if sr!=32000: mono=torchaudio.functional.resample(mono,sr,32000)
 # Compare identical one-second PCM, no path or annotations enter either predictor.
 for i in range(min(3,mono.shape[1]//32000)):
  audio=mono[:,i*32000:(i+1)*32000].contiguous()
  with torch.no_grad():
   ref=base(baseline.preprocess(audio.unsqueeze(1))).float().numpy()[0]
   fp32=model(audio).numpy()[0]
  exported=session.run(None,{'waveform':audio.numpy()})[0][0]
  a=torch.softmax(torch.tensor(ref),0).numpy(); b=torch.softmax(torch.tensor(exported),0).numpy()
  print("PARITY", path.name, i, "logits",float(np.max(np.abs(fp32-exported))),"prob",float(np.max(np.abs(a-b))),"top",a.argmax(),b.argmax(), flush=True)
  assert np.max(np.abs(fp32-exported))<0.02
  assert np.max(np.abs(a-b))<0.01
  assert a.argmax()==b.argmax()
  results.append(dict(file=path.name,second=i,referenceLogits=ref.tolist(),onnxLogits=exported.tolist(),maxProbabilityError=float(abs(a-b).max()),maxFloat32LogitError=float(abs(fp32-exported).max()),top1=baseline.class_order[int(b.argmax())]))
  if not fixtures:
   audio.numpy().astype('<f4').tofile(root/'Tests/Unit/Fixtures/asc-reference.f32')
   fixtures.append(dict(logits=exported.tolist(),probabilities=b.tolist(),sampleRate=32000,source=path.name,audioSHA256=hashlib.sha256(audio.numpy().astype('<f4').tobytes()).hexdigest()))
labels=baseline.class_order
(out/'labels.txt').write_text('\n'.join(labels)+'\n')
(root/'Tests/Unit/Fixtures/asc-reference.json').write_text(json.dumps(fixtures[0],indent=2)+'\n')
revision=subprocess.check_output(['git','-C',str(repo),'rev-parse','HEAD'],text=True).strip()
report=dict(revision=revision,checkpointSHA256=hashlib.sha256(ckpt.read_bytes()).hexdigest(),branch='base_model (unknown)',sampleRate=32000,windowSamples=32000,nFFT=4096,winLength=3072,hopLength=500,nMels=256,melScale='htk',melNorm=None,center=True,padMode='reflect',power=2,log='natural log(mel + 1e-5), float16 rounding',classes=labels,results=results,scope='Conversion parity only, not ASC accuracy or iPhone microphone validation',torch=torch.__version__,torchaudio=torchaudio.__version__,onnxruntime=ort.__version__)
(root/'Docs/ASC/conversion-parity.json').write_text(json.dumps(report,indent=2)+'\n')
asset=dict(id='cpMobile',revision=revision,frameworkVersion='ONNX Runtime 1.28.2 CPU; CP-Mobile generic FP32 with FP16-rounded source weights/features',source='https://github.com/CPJKU/dcase2025_task1_inference',license='上游仓库未提供明确许可证；本地研究验证，公开再分发前需向权利人确认。',modelFile='cp-mobile.onnx',labelsFile='labels.txt',files=[])
for filename in ['cp-mobile.onnx','labels.txt']:
 data=(out/filename).read_bytes(); asset['files'].append(dict(path=filename,bytes=len(data),sha256=hashlib.sha256(data).hexdigest(),source=f'https://github.com/CPJKU/dcase2025_task1_inference/tree/{revision}'))
(out/'ASCManifest.json').write_text(json.dumps(asset,ensure_ascii=False,indent=2)+'\n')
print(json.dumps(report,indent=2))

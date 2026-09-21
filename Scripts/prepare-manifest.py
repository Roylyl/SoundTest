#!/usr/bin/env python3
"""Assemble the app's immutable resource manifest from audited provenance files."""
import json,pathlib,hashlib
root=pathlib.Path(__file__).resolve().parents[1]
source=json.loads((root/'Docs/SherpaModelFiles.json').read_text())
assets=[]
for model in ['zipformer','cedTiny','cedMini']:
    files=[f for f in source if f['modelID']==model and (f['path'].endswith('.onnx') or f['path'].endswith('.csv'))]
    asset=dict(id=model,revision=files[0]['revision'],frameworkVersion='sherpa-onnx 1.13.8 / ONNX Runtime 1.28.2 · CPU',
        source=files[0]['source'].split('/resolve/')[0],
        license=('Apache-2.0；k2转换模型卡未另列许可，原作者权重许可依据见Docs。' if model!='zipformer' else 'Apache-2.0（固定转换模型卡声明）。'),
        modelFile='model.int8.onnx',labelsFile='class_labels_indices.csv',
        files=[dict(path=pathlib.Path(f['path']).name,bytes=f['sizeBytes'],sha256=f['sha256'],source=f['source']) for f in files])
    assets.append(asset)
yam=json.loads((root/'ModelLibrary/yamnet/YamnetManifest.json').read_text())
assets.append(dict(id='yamnet',revision=yam['version'],frameworkVersion='TensorFlow Lite C 2.17.0 · CPU',source=yam['source'],license=yam['license'],modelFile='yamnet.tflite',labelsFile='yamnet_label_list.txt',files=[dict(f,source=yam['source']+('#associated-yamnet_label_list.txt' if f['path'].endswith('.txt') else '')) for f in yam['files'] if f['path']!='LICENSE']))
for asset in assets:
    for f in asset['files']:
        data=(root/'ModelLibrary'/asset['id']/f['path']).read_bytes()
        assert len(data)==f['bytes'] and hashlib.sha256(data).hexdigest()==f['sha256'],f
text=json.dumps(assets,ensure_ascii=False,indent=2)+'\n'
(root/'ModelsManifest.json').write_text(text)
(root/'SoundTest/ModelsManifest.json').write_text(text)
print(json.dumps({'models':len(assets),'files':sum(len(a['files']) for a in assets),'bytes':sum(f['bytes'] for a in assets for f in a['files'])}))

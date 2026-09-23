#!/usr/bin/env python3
"""Seed disposable UI fixtures only on a simulator named SoundTest Batch QA*.

Install the built app first, then run this script with that simulator's UDID.
These records exercise list deletion, not recognition accuracy. Never use it on
an existing development/device data container. The UI test clears these records.
"""
import copy
import json
import subprocess
import sys
import time
import wave
from pathlib import Path


def simctl(*args):
    return subprocess.check_output(['xcrun', 'simctl', *args], text=True).strip()


udid = sys.argv[1]
devices = json.loads(simctl('list', 'devices', '-j'))['devices']
device = next(d for group in devices.values() for d in group if d['udid'] == udid)
assert device['name'].startswith('SoundTest Batch QA'), 'Refusing to seed a normal development simulator'
root = Path(simctl('get_app_container', udid, 'com.roylyl.soundtest.ios.a941f206', 'data'))
sessions = root / 'Documents' / 'Sessions'
assert not sessions.exists() or not any(sessions.rglob('*.json')), 'Refusing to overwrite existing logs'
(sessions / 'BatchGroups').mkdir(parents=True, exist_ok=True)
now = time.time() - 978307200  # JSONEncoder Date: seconds since 2001-01-01.
prefix = '11111111-1111-4111-8111-1111111111'
group_id = prefix + '00'
options = dict(mode='单段识别', windowSeconds=0.975, stepSeconds=0.975, mergeGapSeconds=0,
               threads=2, thresholds=dict(petVocalization=0.3, cough=0.3, laughter=0.3, applause=0.3),
               mappingVersion='soundtest-zh-v1')
asset = dict(id='yamnet', revision='UI fixture', frameworkVersion='UI fixture', source='Local generated fixture',
             license='Generated for UI testing', modelFile='unused', labelsFile='unused', files=[])
base = dict(schemaVersion=2, appVersion='2.0.0', startedAt=now, endedAt=now, model='yamnet', asset=asset,
            options=options, device='Isolated UI-test simulator', actualInput='Generated UI fixture; no inference',
            actualInputUID='ui-fixture', audioSeconds=0, modelSampleRate=16000, loadMS=0, inferenceMS=0,
            status='完成', thermalStart='', thermalEnd='', windows=[], events=[], anomalies=[],
            metricDefinition='UI fixture only. No recognition or timing measurement.',
            material=dict(testCase='UI', sampleID='UI', source='Generated UI fixture', permission='Generated for testing',
                          manualLabel='Not a recognition result', inputMethod='直接导入'))
for suffix, filename in [('01', 'UI_删除_A.wav'), ('02', 'UI_保留_B.wav'), ('03', 'UI_组内文件.wav')]:
    record = copy.deepcopy(base)
    record['id'] = prefix + suffix
    record['material']['filename'] = filename
    if suffix == '03':
        record['batch'] = dict(groupID=group_id, itemID=prefix+'11', index=0, total=2)
    for extension in ['.json', '.summary.json']:
        (sessions / (record['id'] + extension)).write_text(json.dumps(record, ensure_ascii=False))
group = dict(schemaVersion=1, id=group_id, name='UI 批量日志测试', startedAt=now, endedAt=now,
             model='yamnet', options=options, status='已完成', items=[
                 dict(id=prefix+'11', filename='UI_组内文件.wav', status='完成', recordID=prefix+'03', audioSeconds=0, inferenceMS=0),
                 dict(id=prefix+'12', filename='UI_失败示例.wav', status='失败', error='UI fixture: invalid WAV')
             ])
(sessions / 'BatchGroups' / (group_id + '.json')).write_text(json.dumps(group, ensure_ascii=False))
samples = root / 'Documents' / 'Samples'
samples.mkdir(exist_ok=True)
with wave.open(str(samples / 'UI-preserve-after-clear.wav'), 'wb') as output:
    output.setparams((1, 2, 16000, 160, 'NONE', 'not compressed'))
    output.writeframes(b'\0\0' * 160)
print(root)

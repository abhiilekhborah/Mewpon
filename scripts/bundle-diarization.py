#!/usr/bin/env python3
"""Package a source-built, fixed C helper and verified upstream offline runtime."""
from pathlib import Path
import hashlib,json,shutil,subprocess
root=Path(__file__).resolve().parents[1]
runtime=root/'ThirdParty/sherpa/sherpa-onnx-v2.0.0-osx-universal2-shared-no-tts'
models=root/'LocalModels/Diarization'
if not (runtime/'lib/libsherpa-onnx-c-api.dylib').exists() or not (models/'embedding.onnx').exists():
    print('Optional diarization runtime/models not present; backend remains unavailable.')
    raise SystemExit(0)
provenance=json.loads((root/'Verification/Phase7/diarization-provenance.json').read_text())
archive=root/'ThirdParty/sherpa-downloads/runtime.tar.bz2'
assert hashlib.sha256(archive.read_bytes()).hexdigest()==provenance['runtime_archive_sha256'],'Runtime archive changed'
paths=[models/'embedding.onnx',models/'sherpa-onnx-pyannote-segmentation-3-0/model.int8.onnx']
for source,meta in zip(paths,provenance['models']):
    assert source.stat().st_size==meta['bytes'] and hashlib.sha256(source.read_bytes()).hexdigest()==meta['sha256'],'Diarization model changed'
destination=root/'build/Mewpon.app/Contents/Resources/Diarization'
(destination/'lib').mkdir(parents=True,exist_ok=True)
for name in ['libsherpa-onnx-c-api.dylib','libonnxruntime.dylib']:
    target=destination/'lib'/name
    if target.exists():target.chmod(0o755)
    shutil.copy2(runtime/'lib'/name,target);target.chmod(0o755)
    subprocess.run(['install_name_tool','-id','@rpath/'+name,str(target)],check=True,capture_output=True)
subprocess.run(['xcrun','clang','-O2','-mmacosx-version-min=14.0','-I'+str(runtime/'include'),str(root/'NativeHelpers/MewponDiarizer.c'),'-L'+str(runtime/'lib'),'-lsherpa-onnx-c-api','-Wl,-rpath,@loader_path/lib','-o',str(destination/'mewpon-diarizer')],check=True)
for path in paths:shutil.copy2(path,destination/('segmentation.onnx' if path.name=='model.int8.onnx' else path.name))
shutil.copy2(root/'Verification/Phase7/diarization-provenance.json',destination/'provenance.json')
notices=destination/'Licenses';notices.mkdir(exist_ok=True)
for name in ['sherpa-onnx-LICENSE.txt','onnxruntime-LICENSE.txt','onnxruntime-ThirdPartyNotices.txt','3D-Speaker-LICENSE.txt']:
    shutil.copy2(root/'ThirdPartyNotices'/name,notices/name)
shutil.copy2(models/'sherpa-onnx-pyannote-segmentation-3-0/LICENSE',notices/'CNRS-segmentation-MIT.txt')
shutil.copy2(root/'Verification/Phase7/embedding-upstream-readme.md',notices/'embedding-upstream-model-card.md')
for binary in [*sorted((destination/'lib').glob('*.dylib')),destination/'mewpon-diarizer']:
    subprocess.run(['codesign','--force','--sign','-',str(binary)],check=True,capture_output=True)
print('Packaged offline diarization C helper, two runtime libraries and two licensed local models.')

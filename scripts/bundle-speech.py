#!/usr/bin/env python3
"""Package verified Homebrew whisper.cpp runtime and a separately verified model.
No network access; run before outer app signing. Optional for source-only builds.
"""
from pathlib import Path
import subprocess,shutil,re,json,hashlib
root=Path(__file__).resolve().parents[1]
app=root/'build/Mewpon.app/Contents/Resources/Speech'
binary=Path('/opt/homebrew/bin/whisper-cli')
model=root/'LocalModels/ggml-base.bin'
if not binary.exists() or not model.exists():
    print('Offline Whisper runtime not packaged: install the verified engine and local model first.')
    raise SystemExit(0)
provenance=json.loads((root/'Verification/Phase7/model-provenance.json').read_text())
assert hashlib.sha256(model.read_bytes()).hexdigest()==provenance['sha256'],'Speech model hash changed'
app.mkdir(parents=True,exist_ok=True);(app/'lib').mkdir(exist_ok=True)
queue=[(binary.resolve(),app/'whisper-cli')]
for pattern in ['libggml-cpu*.dylib','libggml-metal*.dylib','libggml-blas*.dylib']:
    for path in Path('/opt/homebrew/opt/ggml/lib').glob(pattern):queue.append((path.resolve(),app/'lib'/path.name))
queue += [(p.resolve(),app/"lib"/p.name) for p in Path("/opt/homebrew/opt/ggml/libexec").glob("*.so")]
seen=set();sources=set()
def dependencies(p):
    lines=subprocess.check_output(['otool','-L',str(p)],text=True).splitlines()[1:]
    return [line.strip().split(' (')[0] for line in lines]
def resolve(dep,src):
    if dep.startswith('/'):return Path(dep).resolve()
    name=dep.split('/')[-1]
    for candidate in [src.parent/name,src.parent.parent/'lib'/name,*[Path('/opt/homebrew/opt')/f/'lib'/name for f in ['whisper.cpp','ggml','libomp','llama.cpp']]]:
        if candidate.exists():return candidate.resolve()
    raise RuntimeError('Unresolved speech runtime dependency: '+dep)
while queue:
    src,dst=queue.pop(0)
    if dst.name in seen:continue
    seen.add(dst.name);sources.add(src)
    if dst.exists():dst.chmod(0o755)
    shutil.copy2(src,dst)
    dst.chmod(0o755)
    for dep in dependencies(src):
        if dep.startswith('/usr/lib/') or dep.startswith('/System/'):continue
        resolved=resolve(dep,src)
        if resolved==src:continue
        assert str(resolved).startswith('/opt/homebrew/Cellar/'),'Unexpected speech library location'
        target=app/'lib'/dep.split('/')[-1]
        queue.append((resolved,target))
        relative='@loader_path/'+('lib/' if dst.name=='whisper-cli' else '')+target.name
        subprocess.run(['install_name_tool','-change',dep,relative,str(dst)],check=True,capture_output=True)
    if dst.suffix=='.dylib':subprocess.run(['install_name_tool','-id','@rpath/'+dst.name,str(dst)],check=True,capture_output=True)
# Homebrew's Metal backend may use external resource libraries.
share=Path('/opt/homebrew/opt/ggml/share/ggml')
if share.exists():shutil.copytree(share,app/'metal',dirs_exist_ok=True)
if (app/'ggml-base.bin').exists():(app/'ggml-base.bin').chmod(0o644)
shutil.copy2(model,app/'ggml-base.bin')
shutil.copy2(root/'Verification/Phase7/model-provenance.json',app/'model-provenance.json')
small=root/'LocalModels/ggml-small.bin'
if small.exists():
    small_provenance=root/'Verification/Phase7/hindi-model-provenance.json'
    details=json.loads(small_provenance.read_text())
    assert small.stat().st_size==details['bytes'] and hashlib.sha256(small.read_bytes()).hexdigest()==details['sha256'],'Hindi model hash changed'
    target=app/'ggml-small.bin'
    if target.exists():target.chmod(0o644)
    shutil.copy2(small,target)
    shutil.copy2(small_provenance,app/'hindi-model-provenance.json')
notices=app/'Licenses'
notices.mkdir(exist_ok=True)
shutil.copy2(root/'ThirdPartyNotices/OpenAI-Whisper-LICENSE.txt',notices/'OpenAI-Whisper-LICENSE.txt')
notices=app/'Licenses';notices.mkdir(exist_ok=True)
for src in sources:
    parts=src.parts
    if 'Cellar' not in parts:continue
    pos=parts.index('Cellar');formula=Path(*parts[:pos+3])
    for f in formula.rglob('*'):
        if f.is_file() and f.name.lower().startswith(('license','copying','notice','copyright')):
            dest=notices/parts[pos+1]/f.relative_to(formula);dest.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(f,dest)
for f in [*sorted(p for p in (app/'lib').iterdir() if p.is_file()),app/'whisper-cli']:
    # The build script replaces these ad-hoc signatures with its stable identity.
    subprocess.run(['codesign','--force','--sign','-',str(f)],check=True,capture_output=True)
print('Packaged offline Whisper runtime:',len(seen),'binaries; verified multilingual base model')

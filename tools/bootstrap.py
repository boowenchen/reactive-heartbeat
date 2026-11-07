"""Fetch pinned official Solidity dependencies without git init or global writes."""
from pathlib import Path
import io, json, urllib.request, zipfile

ROOT = Path(__file__).resolve().parents[1]
DEPS = {
    'reactive-lib': ('Reactive-Network/reactive-lib-omni', '3ade0dcf1d27e67e5783ef807e73a1b9e0c0cce8'),
    'forge-std': ('foundry-rs/forge-std', 'dc647cc030d9d65910d8f1172a0cde48d7106e32'),
}
for project in ('.',):
    base = ROOT
    base.mkdir(exist_ok=True)
    for name, (repo, commit) in DEPS.items():
        target = base / 'lib' / name
        if target.exists():
            continue
        raw = urllib.request.urlopen(f'https://codeload.github.com/{repo}/zip/{commit}').read()
        with zipfile.ZipFile(io.BytesIO(raw)) as archive:
            for item in archive.infolist():
                rel = Path(*Path(item.filename).parts[1:])
                if not rel.parts or item.is_dir():
                    continue
                out = (target / rel).resolve()
                if not out.is_relative_to(target.resolve()):
                    raise ValueError('Unsafe archive path')
                out.parent.mkdir(parents=True, exist_ok=True)
                out.write_bytes(archive.read(item))
    (base / 'dependencies.lock.json').write_text(json.dumps(DEPS, indent=2)+'\n', encoding='utf-8')
print('Pinned dependencies ready')

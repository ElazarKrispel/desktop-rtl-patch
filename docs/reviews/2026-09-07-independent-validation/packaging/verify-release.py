"""Read-only byte comparison of downloaded release ZIP against pinned Git blobs."""
from pathlib import Path
import hashlib
import json
import subprocess
import zipfile

repo = Path(__file__).resolve().parents[4]
out = Path(__file__).resolve().parent
downloads = Path('C:/rtl-audit-20260907-downloads')
commit = '02cc70a8b750de4bc88b740cf8a64f292a5c0325'
zip_path = downloads / 'desktop-rtl-patch-2.5.0.zip'
digest = hashlib.sha256(zip_path.read_bytes()).hexdigest()
sums = (downloads / 'SHA256SUMS.txt').read_text(encoding='utf-8-sig')
matching_rows = [line for line in sums.splitlines() if line.split() == [digest, zip_path.name]]
metadata = json.loads((out / 'release-metadata.json').read_text(encoding='utf-8-sig'))
asset = next(a for a in metadata['assets'] if a['name'] == zip_path.name)
files = []
with zipfile.ZipFile(zip_path) as archive:
    roots = {name.replace('\\', '/').split('/')[0] for name in archive.namelist()}
    assert len(roots) == 1, 'Ambiguous archive root'
    archive_root = roots.pop()
    for name in archive.namelist():
        if name.endswith('/'):
            continue
        relative = name.replace('\\', '/').removeprefix(archive_root + '/')
        data = archive.read(name)
        blob = subprocess.run(['git', 'show', f'{commit}:{relative}'], cwd=repo, capture_output=True)
        if blob.returncode:
            status = 'NOT_IN_COMMIT'
        elif blob.stdout == data:
            status = 'BYTE_IDENTICAL'
        elif blob.stdout.replace(b'\r\n', b'\n') == data.replace(b'\r\n', b'\n'):
            status = 'LINE_ENDINGS_ONLY'
        else:
            status = 'CONTENT_DIFFERS'
        files.append({'path': relative, 'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest(), 'comparison': status})
include = {'scripts', 'src', 'test', 'assets', 'install.ps1', 'Install-Desktop-RTL.vbs', 'Install-Desktop-RTL.cmd', 'Desktop-RTL-Tray.vbs', 'Desktop-RTL-Settings.vbs', 'README.md', 'LICENSE'}
tracked = subprocess.check_output(['git','ls-tree','-r','--name-only',commit],cwd=repo).decode().splitlines()
expected = {p for p in tracked if p.split('/')[0] in include}
actual = {f['path'] for f in files}
result = {
    'commit': commit, 'downloadedAsset': zip_path.name, 'bytes': zip_path.stat().st_size, 'sha256': digest,
    'exactPublishedChecksumMatch': len(matching_rows) == 1, 'githubMetadataDigestMatch': asset['digest'] == 'sha256:' + digest,
    'archiveRoot': archive_root, 'files': files, 'missingFromIncludePolicy': sorted(expected - actual), 'extraFiles': sorted(actual - expected),
    'scope': 'Archive read in memory. No released script or application executed. CRLF-only differences are reported separately from byte identity.',
}
(out / 'release-byte-validation.json').write_text(json.dumps(result, indent=2), encoding='utf-8')
print(json.dumps({k: v for k,v in result.items() if k != 'files'}, indent=2))
print({s: sum(f['comparison'] == s for f in files) for s in sorted({f['comparison'] for f in files})})
assert len(matching_rows) == 1 and result['githubMetadataDigestMatch']
assert not result['missingFromIncludePolicy']
assert all(f['comparison'] in ('BYTE_IDENTICAL', 'LINE_ENDINGS_ONLY') for f in files)

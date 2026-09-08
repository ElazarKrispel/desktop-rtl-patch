from pathlib import Path
import hashlib
import json
import subprocess

out = Path(__file__).resolve().parent
repo = out.parents[2]
review = 'docs/reviews/2026-09-07-release-readiness/'
head = '3c48cc43514d70137706fa257902008822dc6a8e'
base = '02cc70a8b750de4bc88b740cf8a64f292a5c0325'
def git(*args):
    return subprocess.check_output(['git', *args], cwd=repo)
p = json.loads(git('show',head+':'+review+'PROVENANCE.json'))
rows = []
for item in [dict(path='REPORT.he.md',sha256=p['originalReport']['sha256']), *p['originalEvidence']]:
    raw = git('show',head+':'+review+item['path'])
    have = hashlib.sha256(raw).hexdigest()
    rows.append(dict(path=item['path'],bytes=len(raw),sha256=have,recordedSha256Matches=have==item['sha256']))
result = dict(sourceCommit=base,reviewCommit=head,originMain=git('rev-parse','origin/main').decode().strip(),
    workingBranch=git('branch','--show-current').decode().strip(),
    productDiffFromBaseline=git('diff','--name-only',base,head,'--','scripts','src','test','install.ps1','README.md').decode().splitlines(),
    reviewFiles=git('ls-tree','-r','--name-only',head,'--',review).decode().splitlines(),
    preservedOriginalBlobs=rows,
    note='Hashes computed on Git blobs; Windows checkout CRLF conversion must not be mistaken for original evidence changes.')
(out/'provenance-results.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
assert all(r['recordedSha256Matches'] for r in rows)
assert not result['productDiffFromBaseline']
print('Five original hashes match. Ten review files inventoried. Product code equals baseline.')

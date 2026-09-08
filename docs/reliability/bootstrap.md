# Bootstrap verification gate

Baseline: `02cc70a8b750de4bc88b740cf8a64f292a5c0325`, `install.ps1`.
Related review: [PR #8](https://github.com/ElazarKrispel/desktop-rtl-patch/pull/8).
Validation performed on Windows on 2026-09-08.

## Problem and change

The baseline catches a temporary failure retrieving `SHA256SUMS.txt` and downloads
the source archive instead. It then extracts that unverified archive and reaches
the installer. The same fallback occurs when retrieving the release ZIP fails.
Matching a valid published ZIP once does not exercise either failure path.

The bootstrap now requires both release assets. Any retrieval or hashing error
throws `[INTEGRITY]` before extraction or installation. There is no source archive
fallback and no automatic retry. The user can retry the bootstrap after the
failure. The checksum must be one complete record for the exact expected ZIP
filename, and its full SHA-256 must match. Unrelated records remain permitted;
missing, malformed and duplicate matching records are rejected.

This uses the existing release transport and checksum trust model. It does not
add release signatures, change the pinned version, or alter the tool self-updater.

## Reproduction and results

`test/bootstrap-integrity.tests.ps1` executes the **whole bootstrap**, replacing
network, archive extraction, GUI launch and the CLI call operator target with
test doubles. Hashing is real, over synthetic bytes. Temporary directories and
placeholder script files are created beneath a newly allocated test directory.
No release is downloaded, no real archive is expanded and no installer runs.
The test restores the process environment and retains its synthetic files.

Each of these 11 cases runs in both GUI and headless mode:

| Cases | Required result |
| --- | --- |
| Checksum unavailable; asset unavailable | Clear integrity failure; no fallback, extraction or launch |
| Empty checksum; wrong hash; wrong filename; malformed text; duplicate entry | Clear integrity failure; no extraction or launch |
| Valid text; valid byte content; binary-marker checksum; unrelated additional entry | Exactly one extraction and one mocked installer launch |

Committed evidence:

- [Before, Windows PowerShell 5.1](bootstrap-before.json): 12/22 passed, 10/22
  failed. Both unavailable-asset cases reached fallback and installer; incorrect
  filename, malformed text and duplicate checksums also reached the installer.
- [After, Windows PowerShell 5.1](bootstrap-after.json): 22/22 passed.
- [After, PowerShell 7.6.5](bootstrap-after-ps7.json): 22/22 passed.

The JSON includes the tested script SHA-256, runtime version, every result and
boundary-call counts. The baseline script was materialized from the pinned Git
blob; its line endings may differ from a checkout. No fixture trees are included.

Run from the repository root:

```powershell
powershell.exe -NoProfile -File test/bootstrap-integrity.tests.ps1
```

To repeat the before comparison, materialize `install.ps1` from the baseline into
a separate scratch file and pass it with `-ScriptPath`. That run must exit with a
regression-check failure. Optionally use `-ResultPath` for a JSON record.

## Limits and rollback

Live network failures and a real GUI/CLI installation are **NOT RUN**. The tests
prove the bootstrap's control flow under injected boundary failures; they do not
validate Windows installation, release authenticity or archive contents.

Reverting this commit restores the unsafe fallback. If this change prevents a
release from bootstrapping, repair/upload its matching checksum asset or withdraw
that bootstrap version. Do not restore unverified execution as a recovery step.

# Filesystem boundary hardening

Baseline: `02cc70a8b750de4bc88b740cf8a64f292a5c0325`. This change addresses the independently reproduced F03 junction escape and the associated hardlink write. It does not change the original review in PR #8.

## What changed

The profile prefix check remains necessary but now also checks every existing path component, including the allowed root itself. Missing descendants are checked through their existing parents. Windows reparse points, hardlinked mutation files, device paths, UNC paths and alternate data streams fail closed.

The shared `desktop-rtl-paths.ps1` helper is required in both package validation and deployed runtime. Explicit filesystem wrappers cover recursive deletion, copying and renaming. Recursive operations inspect children before descent; copy-source roots may be read through the official Herdr directory symlink, but linked descendants are rejected. Destination inspection precedes robocopy. Logs, state/config, markers, locks, temporary outputs, downloads/extraction, shortcuts, binary deployment, swap/rollback and Herdr writes use the same checks. Registry and environment operations retain their existing separate behavior; a filesystem guard is not a Registry ownership policy.

The Node editor independently checks fuse, archive, backup and temporary mutation paths. Fuse writes also check the opened file's link count. Archive writes use a random sibling temporary name opened exclusively (`wx`), so the old predictable `app.asar.tmp` cannot redirect or truncate another file. Checks repeat before final rename.

Rejection may deliberately leave cleanup incomplete. The lifecycle PR must retain and report those leftovers; it must never work around rejection by deleting the junction or choosing another traversal mechanism automatically.

## Reproduction and validation

Windows, Windows PowerShell `5.1.26100.9168`, Node `v24.14.0`. Only minimal synthetic files in unique temporary directories were used. Fixtures are retained. No original application, user profile, Registry, shortcut, named event or working process was changed.

Run against the fixed checkout:

```powershell
powershell.exe -NoProfile -File test/path-boundaries.harness.ps1
node test/path-boundaries.mjs
```

To reproduce against a separate unchanged baseline checkout, pass its absolute path; do not reset a working checkout:

```powershell
powershell.exe -NoProfile -File test/path-boundaries.harness.ps1 -RepoRoot C:\baseline-checkout -Baseline
node test/path-boundaries.mjs --baseline --editor C:\baseline-checkout\scripts\lib\asar-edit.mjs
```

Observed BEFORE on Windows: the **full production PowerShell fuse wrapper calling the full Node editor** changed an external synthetic binary through a staging junction. The full directory injection function changed external synthetic HTML and created a payload. The standalone full Node CLI also changed an external hardlinked file and injected an archive through a junction. Direct outside-prefix rejection and a normal inside-root file were positive controls. This is stronger evidence than the original extracted-function Linux probe, but remains synthetic, not an installation cycle.

Observed AFTER:

| Test surface | Result |
|---|---|
| PowerShell fuse wrapper, directory injection, state write through junction | PASS: rejected, external sentinels unchanged |
| Missing descendants, junction selected as root, sibling-prefix control | PASS: rejected |
| Child junction before recursive removal, copy, mirror | PASS: rejected before filesystem operation |
| Ordinary directory injection plus actual verifier | PASS |
| Node direct outside, junction ancestor, hardlinked binary | PASS: rejected, external sentinels unchanged |
| Node archive junction and backup destination junction | PASS: rejected, original archive preserved |
| Ordinary archive with hostile legacy temporary hardlink | PASS: archive updated, external temporary sentinel unchanged |

The first two normal renderer test runs exposed fixture mistakes (missing config and assuming an `ok` object from a boolean verifier). Those runs failed and were corrected in the fixture; the final harness passes. They are not counted as product passes.

## Limits and deployment gate

- Deletion/mirror scenarios are preventative rejection tests. They do **not** establish that every prior PowerShell/robocopy version actually followed a junction during deletion.
- The checks are preflight and immediate rechecks. A malicious same-user process can still replace an ancestor between a check and an OS operation. **Concurrent path replacement is NOT RUN and no race-proof claim is made.** A stronger adversarial guarantee would require handle-relative operations or access-controlled staging and a reviewed native implementation.
- Full synthetic installation and rollback regression depends on the PR-00 isolated runner; real installation/uninstall and real shortcut/Registry integration remain NOT RUN without specific authorization.
- UNC or redirected managed roots are intentionally refused. No fallback traverses them. Ordinary Unicode local paths remain supported.
- Packaging must include the helper. A partial old runtime that lacks it must fail to load, not silently downgrade boundary protection.

Rollback: revert this focused commit on the same branch, without deleting fixtures or user data. Reverting restores the known junction/hardlink vulnerability and is not a safe public release choice.

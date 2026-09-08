# Persistent partial cleanup

Baseline: `02cc70a8b750de4bc88b740cf8a64f292a5c0325`. Related independent evidence: PR #9, F02/F03. This change depends on PR-00 isolation and PR-01 data retention.

The uninstall engine records `CleanupPending` in an atomic `management.json` before deleting owned resources. It retains installed-version evidence during a partial removal. A second invocation derives all removal paths from the selected profile; receipt strings are diagnostic text and never deletion authority. The receipt is removed only after cleanup succeeds.

Enumeration includes managed directories and metadata without requiring an executable or installed source. Retained user config, data, logs and the idle lock file alone do not count as an installed app. Unrecognized or unreadable receipts prevent automatic installation. Reading status no longer moves malformed state files. The installer shows cleanup before source discovery, the tray continues to list the app, and update cannot recreate it while cleanup is pending.

Run `powershell.exe -NoProfile -ExecutionPolicy Bypass -File test\cleanup-receipt.tests.ps1`. To reproduce the original behavior, pass `-RepositoryRoot <clean baseline checkout> -ExpectBaseline`, keeping the test and isolation helper from this branch.

Executed on Windows PowerShell 5.1: baseline 5 assertions reproduced loss of discovery and state after partial removal; fixed 13 assertions passed. The test holds a real exclusive lock on a synthetic non-executable file, attempts real fixture deletion, removes the fixture executable, reloads the product library, and models the source as absent. It then releases the lock and completes removal. The existing 162-assertion harness and 14 isolation assertions also passed before stacking with subsequent fixes.

Registry cleanup, process discovery and shortcuts are explicit test models. A library reload proves independence from in-memory state, not a complete OS reboot. Real reboot, live tray/GUI and Registry integration remain NOT RUN. No application or user data was changed.

Rollback: retain `management.json` and user data; older versions do not understand cleanup intent and must not resume automatic patching. Revert UI changes only together with the management reader, or complete cleanup using a compatible tool first. Do not delete evidence to make an old version report Fresh.

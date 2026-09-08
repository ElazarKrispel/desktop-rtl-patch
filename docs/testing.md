# Local tests on Windows

Run from a checkout with Windows PowerShell 5.1 and Node.js available:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File test\Run-Tests.ps1
```

The runner checks PowerShell parsing and UTF-8 BOM requirements, keeps the shared
libraries ASCII, checks both JavaScript files, and runs each harness in a fresh
PowerShell process. Missing dependencies fail the run; required checks never skip.
It does not show the installer, start target apps, or run their install cycles.

`isolation.harness.ps1` tests that forbidden operating-system calls are rejected,
including when the caller catches the exception. `renderer-injection.harness.ps1`
loads the real library and tests injection, profiles, settings, retry metadata,
synthetic uninstall and the real Node fuse editor. Its non-executable file lock and
file deletions are real Windows filesystem operations inside unique temporary roots.

The shared `isolated-test-support.ps1` redirects profile, source and temporary
directories and restores environment values during cleanup. It models an empty
process set, legacy watcher and Registry cleanup at explicit product boundaries.
The legacy Run read uses a fake key. Lower-level process, network and Registry
operations remain traps; unexpected calls are retained in a violation list even
when product code catches the error. Filesystem cmdlets check fixture boundaries.
`WScript.Shell` is a shortcut recorder that saves text markers, never real links.
Named synchronization objects must carry the unique per-run test prefix.

This helper is not an OS security sandbox for untrusted scripts. Direct .NET,
native executable calls and module-qualified commands can bypass PowerShell
function wrappers. Review new call paths before running them, especially product
top-level code. Do not add a broad bypass to make a suite pass. Real Registry,
COM, launcher, application, concurrent-worker and clean-machine integration tests
need a separately approved isolated Windows environment; these suites do not prove
them. The quit-event test only checks handle lifetime, not tray worker recovery.

For new suites, dot-source the helper in a disposable process, call
`Initialize-RtlTestSandbox -RepositoryRoot ...`, load audited product code, then
call `Set-RtlTestProductBoundaries`. Create synthetic files only below the returned
root. Call `Assert-RtlTestIsolation` before reporting success and
`Complete-RtlTestSandbox` in `finally`. The cleanup validates its exact root and
rejects reparse points; link-specific tests need separately reviewed cleanup.
Never reuse production event names, user profiles or existing temporary fixtures.

The browser example `bidi-harness.html` is a manual demonstration and is not
automated renderer DOM coverage. A passing injection test does not prove streaming,
editing, clipboard behavior, or runtime compatibility with an application release.

`herdr-lifecycle.harness.ps1` checks private data and per-app RTL preference
retention, the uninstall CLI operation tail with `PurgeLogs`, reuse of retained
TOML, and the shared Herdr launch request used by the shortcut and manager.
Launch is captured rather than executed. UTF-8 launcher bytes include a Hebrew
path with spaces; this is not a terminal or shell end-to-end test.

# Operation result consumers

Baseline: `02cc70a8b750de4bc88b740cf8a64f292a5c0325`.
Related review: [PR #8](https://github.com/ElazarKrispel/desktop-rtl-patch/pull/8).
This change depends on the PR-03 engine result and durable result helpers. It is
not a standalone compatible upgrade of the scripts without their shared library.

## Behavior

CLI install/update, GUI install, tray update passes and the settings rebuild
fallback now inspect `Success`. Deferred, Busy, Blocked, Partial and Failed do not
produce success or install the agent. CLI operations return the shared exit codes:
0 success, 2 deferred, 3 busy, 4 blocked, 5 partial, 1 failed.

Uninstall callers persist the outcome before agent cleanup. Unsuccessful removal
leaves the agent available. Tray removal uses a managed background runspace;
the tray waits for its actual completion, then shows a modal result containing
status, reason, leftover paths and the next action. Only after acknowledgment may
last-agent cleanup run. A running copy is not stopped implicitly; the returned
result tells the user to close it. A busy tray explicitly says removal has not
started. A completion-record failure is reported as Failed, retains leftover
details and prevents agent teardown.

The tray persists a unique operation ID and acknowledges that ID only. Startup
checks all known profiles for unacknowledged uninstall results, including profiles
no longer considered installed. Graceful tray quit requests wait until an active
uninstall has saved and displayed its result. Forced termination of the operating
system process cannot guarantee completion; the cleanup receipt remains the
recovery mechanism for an interrupted operation.

The GUI and tray show `VerificationPending` as requiring repair. GUI runtime
dialogs and the renderer are otherwise unchanged.

## Evidence

Run `powershell.exe -NoProfile -File test/operation-callers.tests.ps1` from the
repository root. `-RepoRoot` supports a separate baseline checkout and
`-ResultPath` records JSON. The test copies only CLI scripts into a newly created
synthetic fixture directory. A stub library supplies engine results, lifecycle,
persistence and dialog boundaries. GUI/tray worker bodies are obtained from the
actual source AST and executed without constructing windows. Two additional
cases use actual PowerShell runspaces with that same synthetic library.

- [Baseline evidence](operation-callers-before.json): 17/59 passed, 42 failed.
  Missing managed completion is recorded as a failed requirement; these entries
  are not claims that the old hidden uninstall process ran in the test.
- [After, Windows PowerShell 5.1](operation-callers-after.json): 60/60 passed.
- [After, PowerShell 7.6.5](operation-callers-after-ps7.json): 60/60 passed.

Cases cover the seven result statuses in each consumer, worker exceptions,
settings fallback, durable-save failure with leftover preservation, and dialog
then acknowledgment then cleanup ordering. Script hashes and runtime versions
are recorded. The baseline has one missing-completion entry where the fixed
version runs two concrete completion-order cases.

NOT RUN: real GUI interaction; startup notifications after a Windows restart;
real Registry, shortcuts, named events, process stopping, filesystem removal,
engine-to-caller integration with real installations, or last-agent cleanup.
No actual application was launched or stopped. Synthetic directories are retained
and are not committed.

## Rollback

Keep the caller and engine result contracts together. Rolling back only the
shared library would make these callers fail; rolling back only the callers
would restore false success. Retain cleanup receipts and saved user data across
any rollback. A package with unresolved operation-result handling must not be
published as a self-service release.

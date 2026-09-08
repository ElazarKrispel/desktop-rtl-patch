# Startup and UI filesystem guard completion

This focused addendum closes startup call sites outside the shared engine's mutation wrappers. Base: `38676af09eacc251d6626c35e18b81dafdbbd501` (PR-02 branch). It remains part of the junction finding; it is not a GUI redesign.

The tray's staged self-update executes before the main library loads. It now loads only `desktop-rtl-paths.ps1`, checks staging and all rollback/marker/readiness candidates before any mutation, and uses guarded removal/rename for both success and recovery. An error emits a startup warning and stops this startup attempt; it does not silently continue into a potentially swapped runtime. Rejected paths and pending update evidence are retained.

Staging must include the path, management and operation-result helpers, tray script/launcher, and a nonempty readiness generation. The operation-result helper is supplied by PR-03; this stack is intended to release together. Missing components fail closed. GUI and tray log-folder creation also use the filesystem guard.

## Evidence

Windows PowerShell `5.1.26100.9168`, synthetic directories only. Before the change, the actual tray startup `If` AST swapped a synthetic bin through a redirected AgentHome and reached the mocked launcher. This is an actual synthetic filesystem mutation, not evidence that every deletion implementation follows every junction. No real tray, application, process, Registry or named event was used.

After the change, all seven cases pass:

1. AgentHome junction: the external tree snapshot is unchanged and no launch occurs.
2. Missing operation-result helper: the existing bin remains active, with no launch.
3. Missing tray launcher: no swap or launch occurs.
4. Junction at `bin.old`: rejected before a partial swap; its external sentinel is unchanged.
5. Ordinary staging: swaps successfully and completes using a simulated readiness record.
6. GUI log-directory creation through a junction: rejected without creating external files.
7. Tray log-directory creation through a junction: rejected without creating external files.

```powershell
powershell.exe -NoProfile -File test/startup-boundaries.tests.ps1
powershell.exe -NoProfile -File test/Run-Tests.ps1
```

The full isolated runner also passed on this combined branch. The first fixture attempt failed because it accidentally assigned a reserved PowerShell variable; that fixture was corrected before the BEFORE reproduction and is not counted as a successful test.

The test executes the production startup AST, binding its script-root variable to the source script directory. Launch and readiness/process existence are simulated. The two directory-creation commands are also extracted from production AST. To repeat the BEFORE case, supply a separate unchanged baseline checkout; do not reset working code:

```powershell
powershell.exe -NoProfile -File test/startup-boundaries.tests.ps1 -Baseline -SourceRoot C:\baseline-checkout
```

Fixtures are retained in unique `rtl-startup-*` temporary directories. No previously blocked cleanup is retried. Real readiness timeout/rollback, tray presentation, concurrent path replacement and real installations remain NOT RUN. Warnings emitted by a hidden launcher still need a real Windows UX check. The shared preflight limitations around same-user path replacement remain unchanged.

The standalone mutation scan also identified `Build-Release.ps1`, a developer release builder. It was not run or changed here and is not claimed to be hardened by this addendum. Registry and environment operations use their existing separate policy.

Rollback: revert this addendum without touching user data or fixtures. That restores the reproduced startup escape and is not appropriate for a public release.

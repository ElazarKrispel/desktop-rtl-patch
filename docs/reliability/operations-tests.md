# Operation engine regression evidence

Run from a Windows checkout with Windows PowerShell 5.1 and Git:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File test\operation-engine.tests.ps1
```

The historical comparison requires commit `02cc70a8b750de4bc88b740cf8a64f292a5c0325` in local Git history. Missing history fails explicitly. The script parses that commit and extracts only its original update and last-agent-cleanup functions. It does not load or install the historical product. The current product library is loaded against the shared isolated test environment.

Validation on 2026-09-08: **52 assertions passed** using Windows PowerShell 5.1.26100.9168 against the integrated working tree. This includes reproducing the historical defects as expected baseline observations.

## Evidence boundaries

| Coverage | Actual behavior exercised | Deliberate boundary model |
| --- | --- | --- |
| Historical Busy and post-swap failure | Original full update function, fixture staging signature, result/state/progress and subsequent Auto control flow | Lock result, source, archive verifier, no-op swap and state sink; this historical case does not demonstrate filesystem rollback |
| Current Busy versus Failed | Actual exclusive Windows file lock for Busy; current update wrapper | Permission exception injected at lock entry; no machine ACL changes |
| Verification and recovery | Current update/receipt functions, atomic file replacement, real fixture directory renames, previous bytes restored, invalid warm signature removed, next Auto blocked before source resolution | Post-swap verifier failure is injected; process-running predicate is explicit, with no process inspection |
| Successful swap lifecycle | Previous tree remains during confirmation and until explicit completion, then real rename into warm staging | Confirmation result supplied by a stub |
| Directory and inline payload proof | Actual injectors, actual active-copy confirmation, real payload hashes/text comparison, valid-tag payload tampering rejected | Synthetic executable and renderer HTML; no renderer/browser launch |
| Archive digest contract | Actual active-copy confirmation compares expected tool digest to verifier output | Archive verifier output supplied by a stub; this suite does not execute Node or prove real archive extraction |
| Native binary proof | Real fixture executable digest and a real file lock that makes its digest unavailable | Version/build verifier supplied by a stub; no Herdr executable or version command runs |
| Deferred preparation | Actual full update dispatcher and app-specific deferral control flow | Electron stage verifier and running predicate supplied by stubs; Herdr build replaced by a trap |
| Pending settings and result identity | Current ASAR fast path returns Deferred without writing state when settings are pending; explicit App identity survives a different active profile | Running predicate and forbidden downstream calls supplied by stubs |
| Last-agent cleanup and retry | Actual exclusive lock on a synthetic neutral-runtime file; baseline silently returns, current function throws Partial, persists cleanup receipt/result, actual managed enumeration rediscovers it; release and retry remove runtime while retaining user config | Setup-mutex wrapper executes synchronously; agent registration and unregistration are mocked, with no Registry/process effects |
| Durable result acknowledgement | Actual write/read and exact-operation acknowledgement, stale acknowledgement cannot mark a newer result | Sequential stale-message simulation; not a concurrent cross-process race proof |

The shared isolation guard rejects unexpected process, Registry, network and named production event calls, including swallowed exceptions. A local rename wrapper validates source and destination under the unique fixture directory. The read-only file-link metadata helper is compiled before the generic Add-Type trap, and checks only the test script during initialization. Ordinary product path checks then use that type. Temporary trees are new per invocation and are removed only after validating their resolved root and descendants. No prior audit fixture is cleaned up.

The suite is an acceptance test for these bounded engine contracts. Actual app launches, browser rendering, Windows Terminal/CMD behavior, real installation/removal, production Registry/shortcuts, process discovery, native version compatibility, crash/restart recovery across separate processes and concurrent record publication remain NOT RUN here.

## Defects caught while developing the regression

- Rollback removed a nonexistent `.rtl-staging.json` marker while warm reuse actually checks `.codexrtl-sig`. The regression requires removing the real signature from the rejected replacement.
- Native active-copy confirmation accepted a null binary digest after a hash read failure. An actual exclusive lock on a synthetic executable reproduced this; a version-verifier stub keeps the test free of process launches. Confirmation must reject unavailable digest evidence.

# Scope of the isolated path-containment test

Pinned repository commit: `02cc70a8b750de4bc88b740cf8a64f292a5c0325`.

The extracted `doFuseOff` function is from `scripts/lib/asar-edit.mjs`. The test invokes it on synthetic binary fixtures inside a temporary directory. It checks a rejected direct outside-root path and a symlink path within the allowed root whose physical target is outside. No real application or user data is used. Temporary fixtures are deleted by the probe.

Run with Node on a system that permits creation of symbolic links:

```sh
node probe-paths.mjs
```

The saved result was produced on Linux with Node v22.16.0. This is not the complete PowerShell pipeline, not a Windows junction test, and not evidence of privilege escalation. A dedicated Windows integration test is still required.

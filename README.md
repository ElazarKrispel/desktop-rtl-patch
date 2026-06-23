# codex-desktop-rtl-patch

Right-to-left (Hebrew / Arabic) support for the **OpenAI Codex desktop app** on Windows —
with **automatic re-patching when Codex updates**, and no administrator rights.

> תמיכת עברית / RTL לאפליקציית **Codex** של OpenAI ב-Windows: טקסט עברי זורם מימין-לשמאל
> ומיושר נכון, קוד נשאר משמאל-לימין (גם קוד `inline` בתוך משפט עברי), והפאצ' **מתעדכן לבד**
> בכל פעם ש-Codex מתעדכן — בלי הרשאות מנהל.

The Codex desktop app renders all chat text left-to-right, which makes Hebrew/Arabic look
broken. This patch makes Hebrew/Arabic **prose** flow right-to-left with correct alignment,
while keeping code blocks and inline `` `code` `` strictly left-to-right and correctly
**isolated** inside a sentence.

## Status

- Tested against Codex `26.616.x` (Microsoft Store) on Windows 11.
- Renderer patch **v0.2.0**; installer + auto-update system **v0.3.0**.
- Verified in-app via the Chrome DevTools Protocol (correct `dir` / `direction` /
  `unicode-bidi` on prose, inline code, lists and user messages).

## Requirements

- Codex desktop (Microsoft Store: `winget install Codex -s msstore`, or a direct download).
- **Node.js** on `PATH` (used only to edit the asar) — `node --version` should work.
- Windows PowerShell 5.1+ (built in).
- **No administrator rights** at any point.

## Install

```powershell
git clone https://github.com/ElazarKrispel/codex-desktop-rtl-patch
cd codex-desktop-rtl-patch
powershell -ExecutionPolicy Bypass -File .\scripts\Install-CodexRtl.ps1
```

This builds a patched copy at `%LOCALAPPDATA%\OpenAI\CodexRtl`, adds a **“Codex (RTL)”**
Start-menu shortcut, and starts a background watcher that keeps the copy patched across
Codex updates. Launch Codex from that shortcut. Your original Store Codex keeps working,
unchanged.

> If “Codex (RTL)” is already running, close it first — the installer swaps the new copy
> into place only while it is closed.

## Automatic updates

The Microsoft Store updates Codex on its own; the patched copy would otherwise fall behind.
A small **background watcher** keeps them in sync:

- It starts at logon via the per-user `HKCU\…\Run` key (**no admin**) and re-checks every
  ~6 hours.
- When it sees a newer Codex, it builds the new patched copy in a **staging** folder and
  swaps it into place **only while “Codex (RTL)” is closed**, via an atomic directory
  rename. It **never** restarts or corrupts a running Codex — if you’re using it, the swap
  waits until you next close it.
- Force an update now: `powershell -File .\scripts\Update-CodexRtl.ps1`
- Install without the watcher: `Install-CodexRtl.ps1 -NoWatcher` (manual updates only).

## Store vs. direct installs

The installer auto-detects how Codex is installed and picks the safe strategy:

- **Microsoft Store (MSIX):** its package files are tamper-protected by a TrustedInstaller
  *process trust label*, so they cannot be patched in place even as an administrator. →
  patched **copy** (above).
- **Direct download (non-Store):** a normal, writable install → patched **in place**
  (no copy, no admin), and re-patched on update.

## Uninstall

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Uninstall-CodexRtl.ps1
```

Removes the patched copy, the shortcut, the watcher and its state. The Store Codex is
unaffected.

## Safety

- The original **Microsoft Store Codex is never modified** — the installer only *reads* it.
- Updates build in a **staging** folder and swap in atomically **only when Codex is
  closed**, so you always launch a complete app, never a half-built one.
- **No administrator rights** at any point (autostart uses your own `HKCU\Run` key).

## How it works

- **`src/codex-rtl-patch.js`** runs in the renderer. For each prose block whose non-code
  text contains Hebrew/Arabic it sets a real **`dir="rtl"`** attribute (correct ordering,
  `text-align: start` alignment, and native bidi isolation). It avoids `unicode-bidi:
  plaintext` and inline styles — the earlier approach used both, and React silently reverted
  the inline styles, which is why inline code intermittently “broke back” to LTR. Injected
  CSS forces every code surface to `direction: ltr` + `unicode-bidi: isolate`, so an English
  `` `code` `` span is an isolated LTR island inside the RTL line. A `MutationObserver`
  re-applies `dir` to streamed/late content and survives React re-renders.
- **`scripts/lib/asar-edit.mjs`** surgically injects the script into `app.asar` (appends to
  the data section and rewrites the header — no full repack). Codex’s “owl-electron” runtime
  loads `app.asar` only, and its `OnlyLoadAppFromAsar` / asar-integrity fuses are disabled,
  so no binary/signature patching is needed.
- **`scripts/lib/codex-rtl-lib.ps1`** resolves the Codex install, builds the patched copy
  with staging + atomic swap, manages the watcher and toasts.

## Direction policy

A line is RTL if its non-code text contains **any** Hebrew/Arabic — so a Hebrew sentence
stays right-to-left even when it opens with `` `code` `` or an English word. Pure-English
lines are left as-is (LTR).

## Testing

- `test/bidi-harness.html` — open in any Chromium browser to eyeball the key cases
  (Hebrew + inline code, raw user messages, lists, code blocks).

## Repository layout

```
src/codex-rtl-patch.js          injected renderer script (the RTL fix)
scripts/Install-CodexRtl.ps1    build patched copy + shortcut + watcher
scripts/Update-CodexRtl.ps1     force a re-patch now
scripts/Uninstall-CodexRtl.ps1  remove the copy, shortcut, watcher, state
scripts/Watch-CodexRtl.ps1      background watcher (auto-update, no admin)
scripts/lib/codex-rtl-lib.ps1   shared logic: resolve, staging+swap, watcher
scripts/lib/asar-edit.mjs       surgical, dependency-free asar editor (Node)
scripts/lib/asar.ps1            pure-PowerShell asar reader (utility)
test/bidi-harness.html          visual bidi test cases
```

## Disclaimer

Unofficial community patch. Not affiliated with OpenAI. It modifies a **local copy** of the
app (Store installs) or a local direct install; the original Microsoft Store package is not
touched. Use at your own risk.

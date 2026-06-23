# codex-desktop-rtl-patch

Right-to-left (Hebrew / Arabic) support for the **OpenAI Codex desktop app** on Windows.

> תמיכת עברית / RTL לאפליקציית **Codex** של OpenAI ב-Windows: טקסט עברי זורם מימין-לשמאל
> ומיושר נכון, בעוד שקוד נשאר משמאל-לימין — גם כשמשובץ קוד `inline` בתוך משפט עברי.

The Codex desktop app renders all chat text left-to-right, which makes Hebrew/Arabic
look broken (wrong alignment, reordered words, misplaced punctuation). This patch makes
Hebrew/Arabic **prose** flow right-to-left with correct alignment, while keeping code
blocks and inline `` `code` `` strictly left-to-right and correctly **isolated** inside a
sentence — so an English token in the middle of a Hebrew line lands where it belongs.

The patch is injected into the app's renderer bundle (`app.asar`) inside a **separate
copy** of the app, so your original Microsoft Store install is never modified.

## Status

- Tested against Codex `26.616.x` (Microsoft Store build) on Windows 11.
- Patch version **0.2.0**. Verified in-app via the Chrome DevTools Protocol (correct
  `dir` / computed `direction` / `unicode-bidi` on prose, code, lists and user messages).

## Requirements

- Codex desktop installed from the Microsoft Store (`winget install Codex -s msstore`, or from openai.com).
- **Node.js** on `PATH` (used only at install time to edit the asar) — check with `node --version`.
- Windows PowerShell 5.1+ (built in).

## Install

```powershell
git clone https://github.com/ElazarKrispel/codex-desktop-rtl-patch
cd codex-desktop-rtl-patch
powershell -ExecutionPolicy Bypass -File .\scripts\Install-CodexRtl.ps1
```

This builds a patched copy at `%LOCALAPPDATA%\OpenAI\CodexRtl` and adds a Start-menu
shortcut **“Codex (RTL)”**. Launch Codex from that shortcut. Your Store app keeps working
from its own shortcut, unchanged.

## Update (after Codex updates itself)

The Store app updates independently; the patched copy stays on the version it was built
from. Rebuild from the latest Store version with:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Update-CodexRtl.ps1
```

## Uninstall

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Uninstall-CodexRtl.ps1
```

## How it works

- **`src/codex-rtl-patch.js`** runs in the renderer. For each prose block whose
  (non-code) text contains Hebrew/Arabic it sets a real **`dir="rtl"`** attribute. A real
  `dir` gives correct ordering, `text-align: start` alignment, **and** native bidi
  isolation. It deliberately avoids `unicode-bidi: plaintext` and inline styles — the
  earlier approach used both, and React silently reverted the inline styles, which is why
  inline code intermittently “broke back” to LTR.
- Injected CSS forces every code surface (`pre`, `code`, `kbd`, CodeMirror / Monaco /
  xterm) to `direction: ltr` + `unicode-bidi: isolate`, so an English `` `code` `` span is
  an isolated LTR island inside the RTL line.
- A lightweight `MutationObserver` re-applies `dir` to streamed / late content and reacts
  to `dir` being stripped, so it survives React re-renders.
- **`scripts/Install-CodexRtl.ps1`** copies the Store app to a writable location and
  **`scripts/lib/asar-edit.mjs`** surgically injects the script into `app.asar` (Codex’s
  “owl-electron” runtime loads `app.asar` only — it does not fall back to an unpacked
  folder). The `OnlyLoadAppFromAsar` and embedded-asar-integrity fuses are disabled in
  this build, so no binary/signature patching is required.

## Direction policy

A line is treated as RTL if its non-code text contains **any** Hebrew/Arabic — so a Hebrew
sentence stays right-to-left even when it opens with `` `code` `` or an English word.
Pure-English lines are left untouched (LTR).

## Testing

- `test/bidi-harness.html` — open in any Chromium browser to eyeball the key cases
  (Hebrew + inline code, raw user messages, lists, code blocks) and compare the old vs new
  strategy side by side.

## Repository layout

```
src/codex-rtl-patch.js        the injected renderer script (source of truth)
scripts/Install-CodexRtl.ps1  build the patched copy + shortcut
scripts/Update-CodexRtl.ps1   rebuild from the latest Store version
scripts/Uninstall-CodexRtl.ps1 remove the patched copy + shortcut
scripts/lib/asar-edit.mjs     surgical, dependency-free asar editor (Node)
scripts/lib/asar.ps1          pure-PowerShell asar reader (utility)
test/bidi-harness.html        visual bidi test cases
```

## Disclaimer

Unofficial community patch. Not affiliated with OpenAI. It modifies a **local copy** of
the app; the original Microsoft Store install is not touched. Use at your own risk.

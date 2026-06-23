# codex-desktop-rtl-patch

**Hebrew / Arabic (right-to-left) support for the OpenAI Codex desktop app on Windows** —
with automatic re-patching when Codex updates, and **no administrator rights**.

The Codex desktop app shows all chat text left-to-right, which makes Hebrew/Arabic look
broken. This makes Hebrew/Arabic **prose** flow right-to-left (correct alignment and
punctuation), while keeping code blocks and inline `` `code` `` strictly left-to-right and
correctly placed inside a sentence — even when an English `` `token` `` sits in the middle
of a Hebrew line.

---

## התקנה מהירה (עברית) 🚀

1. ודאו שמותקנים:
   - **Codex** (מ-Microsoft Store).
   - **Node.js** — הורדה מ-<https://nodejs.org> (לוחצים "LTS"). בודקים בטרמינל: `node --version`.
2. מורידים את הפרויקט: לוחצים על הכפתור הירוק **Code ← Download ZIP** למעלה, ומחלצים. (או `git clone`.)
3. פותחים **PowerShell** בתיקיית הפרויקט (בתוך התיקייה: לחיצה ימנית → "Open in Terminal", או Shift+ימני → "Open PowerShell window here") ומריצים:
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\scripts\Install-CodexRtl.ps1
   ```
4. פותחים את **"Codex (RTL)"** מתפריט Start. זהו! 🎉

> ההרצה הראשונה מעתיקה ~1.6GB ולוקחת כדקה. מכאן זה מתעדכן לבד.
> תמיד פותחים דרך **"Codex (RTL)"** — ה-Codex הרגיל נשאר LTR ולא משתנה.

---

## Requirements

- **Codex desktop** — from the Microsoft Store (`winget install Codex -s msstore`) or a direct download.
- **Node.js** on `PATH` — <https://nodejs.org> (used only to edit the app bundle). Check with `node --version`.
- **Windows PowerShell 5.1+** (built into Windows).
- **No administrator rights** at any point.

## Install

Clone (or **Code → Download ZIP** and extract), then run the installer:

```powershell
git clone https://github.com/ElazarKrispel/codex-desktop-rtl-patch
cd codex-desktop-rtl-patch
powershell -ExecutionPolicy Bypass -File .\scripts\Install-CodexRtl.ps1
```

It builds a patched copy at `%LOCALAPPDATA%\OpenAI\CodexRtl`, adds a **“Codex (RTL)”**
Start-menu shortcut, and starts a background watcher that keeps it patched across Codex
updates. **Your original Store Codex is never touched.**

## Using it

- **Always launch Codex from the “Codex (RTL)” shortcut** — that’s the patched one.
- The plain “Codex” keeps working too, but it stays left-to-right (unpatched).
- Both share the same account and conversations, so you see the same threads either way.
- Don’t run both at the same time (they share data) — just use “Codex (RTL)”. Tip: pin it
  to your taskbar.

## Automatic updates

The Store updates Codex on its own; the patched copy would otherwise fall behind. A small
**background watcher** keeps them in sync:

- Starts at logon via your own `HKCU\…\Run` key (**no admin**) and re-checks every ~6 hours.
- When Codex updates, it rebuilds the patched copy in a **staging** folder and swaps it in
  **only while “Codex (RTL)” is closed** (atomic rename). It **never** restarts or breaks a
  running Codex — if you’re using it, the swap waits until you next close it.
- Force an update now: `powershell -File .\scripts\Update-CodexRtl.ps1`
- Install without the watcher: `Install-CodexRtl.ps1 -NoWatcher`.

## Uninstall

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Uninstall-CodexRtl.ps1
```

Removes the patched copy, the shortcut, the watcher and its state. The Store Codex is
unaffected.

## FAQ / troubleshooting

- **Does the regular Codex now show RTL too?** No — only “Codex (RTL)”. The plain Store
  Codex is intentionally left untouched (LTR).
- **Will I lose my chats / do I need to log in again?** No. Both apps share the same account
  and conversations; “Codex (RTL)” is just a patched copy of the same app.
- **“Node.js was not found.”** Install it from <https://nodejs.org> (LTS), reopen
  PowerShell, and re-run.
- **“Codex (RTL) is running.”** Close it first (check the system tray), then re-run.
- **The install command is blocked.** Use exactly `powershell -ExecutionPolicy Bypass -File
  .\scripts\Install-CodexRtl.ps1` (the `-ExecutionPolicy Bypass` part is what lets it run).
- **Did it work?** After installing, launch “Codex (RTL)” and type a Hebrew sentence with an
  English `` `token` `` in backticks — it should read right-to-left with the code in place.

## How it works

- **`src/codex-rtl-patch.js`** runs in the renderer. For each prose block whose non-code
  text contains Hebrew/Arabic it sets a real **`dir="rtl"`** attribute (correct ordering,
  `text-align: start` alignment, native bidi isolation). It avoids `unicode-bidi: plaintext`
  and inline styles — the previous approach used both, and React silently reverted the
  inline styles, which is why inline code intermittently “broke back” to LTR. Injected CSS
  forces every code surface to `direction: ltr` + `unicode-bidi: isolate`. A
  `MutationObserver` re-applies `dir` to streamed/late content and survives React re-renders.
- **`scripts/lib/asar-edit.mjs`** surgically injects the script into `app.asar` (appends to
  the data section and rewrites the header — no full repack). Codex’s “owl-electron” runtime
  loads `app.asar` only, and its `OnlyLoadAppFromAsar` / asar-integrity fuses are disabled,
  so no binary/signature patching is needed.
- **`scripts/lib/codex-rtl-lib.ps1`** resolves the Codex install, builds the patched copy
  with staging + atomic swap, and manages the watcher.
- **Store vs. direct installs:** Store (MSIX) files are tamper-protected by a TrustedInstaller
  process trust label, so they can’t be patched in place → patched **copy**. A direct
  (non-Store) install is writable → patched **in place** (no copy). The installer auto-detects.

## Direction policy

A line is RTL if its non-code text contains **any** Hebrew/Arabic — so a Hebrew sentence
stays right-to-left even when it opens with `` `code` `` or an English word. Pure-English
lines stay LTR.

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

Unofficial community patch, not affiliated with OpenAI. It modifies a **local copy** of the
app (Store installs) or a local direct install; the original Microsoft Store package is not
touched. Use at your own risk.

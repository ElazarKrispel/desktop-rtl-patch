# desktop-rtl-patch

**Hebrew / Arabic (right-to-left) support for AI desktop apps on Windows**, with a friendly
graphical installer, automatic re-patching when the apps update, and **no administrator
rights**.

Supported apps:

| App | Where it comes from | Patched shortcut |
|---|---|---|
| **OpenAI Codex desktop** (new builds are branded **ChatGPT**) | Microsoft Store | "Codex (RTL)" |
| **OpenCode desktop** (anomalyco / SST) | opencode.ai installer | "OpenCode (RTL)" |

These apps show all chat text left-to-right, which makes Hebrew/Arabic look broken. This tool
makes Hebrew/Arabic **prose** flow right-to-left (correct alignment and punctuation), while
keeping code blocks and inline `` `code` `` strictly left-to-right and correctly placed inside
a sentence, even when an English `` `token` `` sits in the middle of a Hebrew line.

It installs a **separate patched copy** per app; your original installs are never changed.
**No Node.js is required** (the patch uses a Node runtime that already ships inside the app).

## התקנה מהירה (עברית) 🚀

1. ודאו שהאפליקציה שרוצים לתקן מותקנת: **Codex** מה-Microsoft Store (בגרסאות החדשות היא
   כבר נקראת **ChatGPT**), או **OpenCode**.
2. **[⬇️ לחצו כאן להורדת הקובץ (ZIP)](https://github.com/ElazarKrispel/desktop-rtl-patch/archive/refs/tags/v2.0.0.zip)**,
   ומחלצים אותו (לחיצה ימנית על הקובץ → "Extract All").
3. דאבל-קליק על **`Install-Desktop-RTL.vbs`**. נפתח חלון התקנה בעברית. בוחרים את האפליקציה
   בבורר שלמעלה (Codex או OpenCode), לוחצים **"התקן"** וממתינים כדקה.
4. פותחים את **"Codex (RTL)"** או **"OpenCode (RTL)"** משולחן העבודה או מתפריט Start. זהו! 🎉

> בלי הרשאות מנהל ובלי להתקין Node.js. ההעתקה הראשונה לוקחת כדקה, ומכאן זה מתעדכן לבד.
> תמיד פותחים דרך קיצור הדרך עם ה-(RTL); האפליקציה המקורית נשארת LTR ולא משתנה.
> אפשר להתקין לשתי האפליקציות במקביל, כל אחת מנוהלת בנפרד.

## Requirements

* At least one supported app installed:
  * **Codex desktop** from the Microsoft Store (`winget install Codex -s msstore`); new builds
    that install/rename themselves to **ChatGPT** are fully supported, and the patcher detects
    the layout automatically.
  * **OpenCode desktop** (the regular installer from opencode.ai).
* **Windows 10 or 11** with Windows PowerShell 5.1 (built in).
* **No administrator rights**, and **no Node.js** (the patch uses the app's own runtime).

## Install (the easy way)

1. **[⬇️ Download the ZIP](https://github.com/ElazarKrispel/desktop-rtl-patch/archive/refs/tags/v2.0.0.zip)** and extract it.
2. Double-click **`Install-Desktop-RTL.vbs`** (or `Install-Desktop-RTL.cmd`). A small window opens.
3. Pick the app at the top (Codex is the default), click **Install** and wait about a minute.

It builds a patched copy (Codex under `%LOCALAPPDATA%\OpenAI\CodexRtl`, OpenCode under
`%LOCALAPPDATA%\RtlPatch\opencode`), adds an **"(RTL)" shortcut** to the Desktop and Start
menu, and starts a background watcher that keeps the copy patched across app updates.
**Your original installs are never touched.**

## Advanced: one-line install

For technical users who prefer the terminal, open **PowerShell** and paste a single line:

```powershell
irm https://raw.githubusercontent.com/ElazarKrispel/desktop-rtl-patch/v2.0.0/install.ps1 | iex
```

This downloads the same code, pinned to the `v2.0.0` tag (verified against a published
SHA-256 checksum), and opens the installer window. Running a remote script means trusting it;
if you are unsure, prefer the ZIP download above (it is exactly the same code, and you can
read it first).

Headless CLI (both take `-App codex|opencode`, default codex):

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Install-DesktopRtl.ps1 -App opencode
powershell -ExecutionPolicy Bypass -File .\scripts\Update-DesktopRtl.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\Uninstall-DesktopRtl.ps1
```

## Using it

* **Always launch the app from its "(RTL)" shortcut.** That is the patched copy.
* The plain app keeps working too, but it stays left-to-right (unpatched).
* The copy and the original share the same account and conversations, so you see the same
  threads either way.
* Don't run the copy and the original at the same time (they share data); just use the
  "(RTL)" one.

## Automatic updates

The apps update themselves, so a patched copy would otherwise fall behind. A small
**background watcher** (per app) keeps them in sync:

* It starts at logon via your own `HKCU\…\Run` key (**no admin**) and re-checks periodically.
* When the original app updates, the watcher rebuilds the patched copy in a **staging** folder
  and swaps it in **only while the "(RTL)" copy is closed** (atomic rename). It never restarts
  or breaks a running app; if you are using it, the swap waits until you next close it.
* For Codex there is also a **system-tray icon** with update/settings/diagnostics actions.
* Force an update now from the installer window (**"התקן מחדש"**), or run
  `powershell -ExecutionPolicy Bypass -File .\scripts\Update-DesktopRtl.ps1` (add
  `-App opencode` for OpenCode).

## Uninstall

* In the installer window, pick the app and click **"הסר התקנה"** (Remove).
* Or run: `powershell -ExecutionPolicy Bypass -File .\scripts\Uninstall-DesktopRtl.ps1`
  (add `-App opencode` for OpenCode).

It removes that app's patched copy, shortcuts, watcher and state; the other app's install is
untouched. The log folder is kept for diagnostics (add `-PurgeLogs` to delete it too). The
original apps are unaffected.

## Under the hood: per-app notes

**Codex / ChatGPT** (Microsoft Store, MSIX):

* The patch uses the **Node runtime bundled inside the app** (`cua_node`), so nothing extra is
  installed.
* The 2026 builds replaced the app runtime and renamed the main executable to `ChatGPT.exe`,
  moved the renderer, and added a strict Content-Security-Policy. The patcher detects all of
  that automatically; the injected script is loaded as a same-origin file, which the CSP
  allows.
* The original Store package (under `WindowsApps`) is read-only and is only ever **read**.

**OpenCode** (NSIS, per-user):

* **No bundled Node**: the editor runs the copy's own Electron binary as Node via
  `ELECTRON_RUN_AS_NODE` (with `ELECTRON_NO_ASAR` so `fs` reads `app.asar` as a plain file).
* The copy drops `resources\app-update.yml` so its updater never overwrites the patch; updates
  flow only through the original + the watcher.

**Both**, and unlike other RTL patches:

* **The signed executables are never modified.** These builds ship with the embedded
  asar-integrity fuse **disabled**, so only the copy's `app.asar` is edited. Other RTL patches
  flip that fuse on the original signed binary and patch the install in place; this tool does
  neither. A read-only check refuses to proceed if a future build ever ships with the fuse
  enabled, instead of producing a broken copy.
* Everything is **copy-only**: a `[SAFETY]` guard in the code refuses to write anywhere except
  the tool's own staging/copy folders.

## FAQ / troubleshooting

* **Does the regular app now show RTL too?** No, only the "(RTL)" copy. The original is
  intentionally left untouched (LTR).
* **My Codex updated and is now called ChatGPT; Hebrew broke.** Update this tool to v2.0.0+
  and click **"התקן מחדש"** (Reinstall); the new layout is supported.
* **Will I lose my chats or need to log in again?** No. The copy and the original share the
  same account and conversations; the "(RTL)" app is just a patched copy of the same app.
* **Do I need to install Node.js?** No. The patch uses a runtime bundled inside the app.
* **A PowerShell window flashes when I use the `.cmd`.** That is just the launcher closing.
  Use `Install-Desktop-RTL.vbs` for no window at all.
* **"... (RTL) is running."** Close it first (check the system tray), then try again.
* **Something failed.** In the window, click **"העתק לוג"** (Copy log) or **"פתח תיקיית לוגים"**
  and send the log file; it has the technical details. **"אסוף אבחון (ZIP)"** packs a
  sanitized diagnostics bundle.
* **Did it work?** Launch the "(RTL)" copy and type a Hebrew sentence with an English
  `` `token` `` in backticks. It should read right-to-left with the code in place.

## How it works

* **`src/desktop-rtl-patch.js`** runs in the renderer (the same file serves every supported
  app). For each prose block whose non-code text contains Hebrew/Arabic it sets a real
  **`dir="rtl"`** attribute (correct ordering, `text-align: start` alignment, native bidi
  isolation). Injected CSS forces every code surface to `direction: ltr` +
  `unicode-bidi: isolate`. A `MutationObserver` re-applies `dir` to streamed or late content
  and survives framework re-renders. Math/LaTeX and table columns get their own handling,
  configurable from the settings dialog.
* **`scripts/Install-DesktopRtlGui.ps1`** is the graphical installer (WinForms, Hebrew) with
  the app selector. It wraps the shared library, shows progress, and offers
  install / update / open / uninstall per app.
* **`scripts/lib/desktop-rtl-lib.ps1`** holds per-app **profiles** (install location, layout,
  Node strategy, watcher identity) and the engine: resolve the original install, build the
  patched copy with staging plus an atomic swap, inject, verify, and manage the watcher. It
  **only reads** the originals and edits **separate copies**, never the original (a `[SAFETY]`
  guard enforces this).
* **`scripts/lib/asar-edit.mjs`** surgically injects the script into `app.asar` (it appends to
  the data section and rewrites the header, with no full repack) and verifies the result.

## Direction policy

A line is RTL if its non-code text contains **any** Hebrew/Arabic, so a Hebrew sentence stays
right-to-left even when it opens with `` `code` `` or an English word. Pure-English lines stay
LTR. (A firstStrong policy is available in the settings dialog.)

## Repository layout

```
Install-Desktop-RTL.vbs            double-click launcher (no console window)
Install-Desktop-RTL.cmd           alternative launcher (delegates to the .vbs)
Desktop-RTL-Tray.vbs              tray launcher (no console window)
Desktop-RTL-Settings.vbs          settings launcher (no console window)
install.ps1                       advanced one-line web bootstrap (pinned to a tag)
src/desktop-rtl-patch.js          injected renderer script (the RTL fix, configurable)
scripts/Install-DesktopRtlGui.ps1 graphical installer (WinForms, Hebrew, app selector)
scripts/DesktopRtlTray.ps1        system-tray app (auto-update + menu, subsumes the watcher)
scripts/DesktopRtlSettings.ps1    settings dialog (WinForms, Hebrew): direction, surfaces, font
scripts/Install-DesktopRtl.ps1    headless installer (advanced), -App codex|opencode
scripts/Update-DesktopRtl.ps1     force a re-patch now, -App codex|opencode
scripts/Uninstall-DesktopRtl.ps1  remove the copy, shortcuts, tray/watcher, state
scripts/Watch-DesktopRtl.ps1      background watcher (event-driven auto-update, no admin)
scripts/Build-Release.ps1         package a checksummed release asset (maintainer helper)
scripts/lib/desktop-rtl-lib.ps1   shared logic: profiles, resolve, staging+swap, verify, watcher
scripts/lib/asar-edit.mjs         surgical, dependency-free asar editor + verifier (Node)
test/bidi-harness.html            visual bidi test cases
```

## Disclaimer

Unofficial community project, not affiliated with or endorsed by OpenAI or by OpenCode's
makers (anomalyco / SST). It was built for accessibility: Hebrew and Arabic right-to-left
support, which these apps do not yet provide. It modifies **local copies** of the apps and
does **not** redistribute any of their code; it does not bypass authentication, payment, or
access controls, and it never changes the original installs. Modifying an app may not be
permitted by its terms of service, so please review them and use this at your own discretion
and risk. "Codex", "ChatGPT" and "OpenCode" are trademarks of their respective owners; this is
an independent project that only describes its own patch.

# codex-desktop-rtl-patch

**Hebrew / Arabic (right-to-left) support for the OpenAI Codex desktop app on Windows**,
with a friendly graphical installer, automatic re-patching when Codex updates, and
**no administrator rights**.

The Codex desktop app shows all chat text left-to-right, which makes Hebrew/Arabic look
broken. This makes Hebrew/Arabic **prose** flow right-to-left (correct alignment and
punctuation), while keeping code blocks and inline `` `code` `` strictly left-to-right and
correctly placed inside a sentence, even when an English `` `token` `` sits in the middle of
a Hebrew line.

It installs a **separate copy** named **"Codex (RTL)"**; your original Codex is never
changed. **No Node.js is required** (it uses the Node that already ships inside Codex).

## התקנה מהירה (עברית) 🚀

1. ודאו ש-**Codex** מותקן (מ-Microsoft Store).
2. **[⬇️ לחצו כאן להורדת הקובץ (ZIP)](https://github.com/ElazarKrispel/codex-desktop-rtl-patch/archive/refs/tags/v1.1.0.zip)**,
   ומחלצים אותו (לחיצה ימנית על הקובץ → "Extract All").
3. דאבל-קליק על **`Install-Codex-RTL.vbs`**. נפתח חלון התקנה בעברית, לוחצים **"התקן"**
   וממתינים כדקה.
4. פותחים את **"Codex (RTL)"** משולחן העבודה או מתפריט Start. זהו! 🎉

> בלי הרשאות מנהל ובלי להתקין Node.js. ההעתקה הראשונה לוקחת כדקה, ומכאן זה מתעדכן לבד.
> תמיד פותחים דרך **"Codex (RTL)"**. ה-Codex הרגיל נשאר LTR ולא משתנה.

## Requirements

* **Codex desktop**, from the Microsoft Store (`winget install Codex -s msstore`) or a direct download.
* **Windows 10 or 11** with Windows PowerShell 5.1 (built in).
* **No administrator rights**, and **no Node.js** (the patch uses Codex's bundled Node).

## Install (the easy way)

1. **[⬇️ Download the ZIP](https://github.com/ElazarKrispel/codex-desktop-rtl-patch/archive/refs/tags/v1.1.0.zip)** and extract it.
2. Double-click **`Install-Codex-RTL.vbs`** (or `Install-Codex-RTL.cmd`). A small window opens.
3. Click **Install** and wait about a minute.

It builds a patched copy at `%LOCALAPPDATA%\OpenAI\CodexRtl`, adds **"Codex (RTL)"** shortcuts
to the Desktop and Start menu, and starts a background watcher that keeps the copy patched
across Codex updates. **Your original Codex is never touched.**

## Advanced: one-line install

For technical users who prefer the terminal, open **PowerShell** and paste a single line:

```powershell
irm https://raw.githubusercontent.com/ElazarKrispel/codex-desktop-rtl-patch/v1.1.0/install.ps1 | iex
```

This downloads the same code, pinned to the `v1.1.0` tag, and opens the installer window.
Running a remote script means trusting it; if you are unsure, prefer the ZIP download above
(it is exactly the same code, and you can read it first).

## Using it

* **Always launch Codex from the "Codex (RTL)" shortcut.** That is the patched one.
* The plain "Codex" keeps working too, but it stays left-to-right (unpatched).
* Both share the same account and conversations, so you see the same threads either way.
* Don't run both at the same time (they share data); just use "Codex (RTL)".

## Automatic updates

The Store updates Codex on its own, so the patched copy would otherwise fall behind. A small
**background watcher** keeps them in sync:

* It starts at logon via your own `HKCU\…\Run` key (**no admin**) and re-checks periodically.
* When Codex updates, it rebuilds the patched copy in a **staging** folder and swaps it in
  **only while "Codex (RTL)" is closed** (atomic rename). It never restarts or breaks a
  running Codex; if you are using it, the swap waits until you next close it.
* Force an update now from the installer window (**"התקן מחדש"**), or run
  `powershell -ExecutionPolicy Bypass -File .\scripts\Update-CodexRtl.ps1`.

## Uninstall

* In the installer window, click **"הסר התקנה"** (Remove).
* Or run: `powershell -ExecutionPolicy Bypass -File .\scripts\Uninstall-CodexRtl.ps1`

It removes the patched copy, the shortcuts, the watcher and its state. The log folder is kept
for diagnostics (add `-PurgeLogs` to delete it too). The original Codex is unaffected.

## FAQ / troubleshooting

* **Does the regular Codex now show RTL too?** No, only "Codex (RTL)". The plain Codex is
  intentionally left untouched (LTR).
* **Will I lose my chats or need to log in again?** No. Both apps share the same account and
  conversations; "Codex (RTL)" is just a patched copy of the same app.
* **Do I need to install Node.js?** No. The patch uses the Node runtime bundled inside Codex.
* **A PowerShell window flashes when I use the `.cmd`.** That is just the launcher closing.
  Use `Install-Codex-RTL.vbs` for no window at all.
* **"Codex (RTL) is running."** Close it first (check the system tray), then try again.
* **Something failed.** In the window, click **"העתק לוג"** (Copy log) or **"פתח תיקיית לוגים"**
  and send the log file; it has the technical details.
* **Did it work?** Launch "Codex (RTL)" and type a Hebrew sentence with an English `` `token` ``
  in backticks. It should read right-to-left with the code in place.

## How it works

* **`src/codex-rtl-patch.js`** runs in the renderer. For each prose block whose non-code text
  contains Hebrew/Arabic it sets a real **`dir="rtl"`** attribute (correct ordering,
  `text-align: start` alignment, native bidi isolation). Injected CSS forces every code
  surface to `direction: ltr` + `unicode-bidi: isolate`. A `MutationObserver` re-applies `dir`
  to streamed or late content and survives React re-renders.
* **`scripts/Install-CodexRtlGui.ps1`** is the graphical installer (WinForms, Hebrew). It wraps
  the shared library, shows progress, and offers install / update / open / uninstall.
* **`scripts/lib/codex-rtl-lib.ps1`** resolves the Codex install, builds the patched copy with
  staging plus an atomic swap, injects the script with Codex's bundled Node, and manages the
  watcher. It **only reads** the original Codex and edits a **separate copy**, never the
  original (a `[SAFETY]` guard enforces this).
* **`scripts/lib/asar-edit.mjs`** surgically injects the script into `app.asar` (it appends to
  the data section and rewrites the header, with no full repack).

## Direction policy

A line is RTL if its non-code text contains **any** Hebrew/Arabic, so a Hebrew sentence stays
right-to-left even when it opens with `` `code` `` or an English word. Pure-English lines stay
LTR.

## Repository layout

```
Install-Codex-RTL.vbs           double-click launcher (no console window)
Install-Codex-RTL.cmd           alternative launcher (delegates to the .vbs)
Codex-RTL-Tray.vbs              tray launcher (no console window)
install.ps1                     advanced one-line web bootstrap (pinned to a tag)
src/codex-rtl-patch.js          injected renderer script (the RTL fix, configurable)
scripts/Install-CodexRtlGui.ps1 graphical installer (WinForms, Hebrew)
scripts/CodexRtlTray.ps1        system-tray app (auto-update + menu, subsumes the watcher)
scripts/CodexRtlSettings.ps1    settings dialog (WinForms, Hebrew): direction, surfaces, font
scripts/Install-CodexRtl.ps1    headless installer (advanced)
scripts/Update-CodexRtl.ps1     force a re-patch now
scripts/Uninstall-CodexRtl.ps1  remove the copy, shortcuts, tray/watcher, state
scripts/Watch-CodexRtl.ps1      background watcher (event-driven auto-update, no admin)
scripts/Build-Release.ps1       package a checksummed release asset (maintainer helper)
scripts/lib/codex-rtl-lib.ps1   shared logic: resolve, staging+swap, verify, config, watcher
scripts/lib/asar-edit.mjs       surgical, dependency-free asar editor + verifier (Node)
test/bidi-harness.html          visual bidi test cases
```

## Disclaimer

Unofficial community project, not affiliated with or endorsed by OpenAI. It was built for
accessibility: Hebrew and Arabic right-to-left support, which the app does not yet provide. It
modifies a **local copy** of the app and does **not** redistribute any OpenAI code; it does not
bypass authentication, payment, or access controls, and it never changes the original Microsoft
Store package. Modifying the app may not be permitted by OpenAI's terms of service, so please
review them and use this at your own discretion and risk. "Codex" is a trademark of OpenAI;
this is an independent project that only describes its own patch.

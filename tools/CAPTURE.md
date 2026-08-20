# Capturing the README screenshots

Maintainer notes. `tools/` is not shipped in the release package, and `tools/raw/` is
git-ignored: only the composed PNGs under `assets/` are committed.

## What each script does

| Script | Output |
|---|---|
| `Build-Banner.ps1` | `assets/banner.svg` + `assets/social-preview.svg` from one data table |
| `Render-Assets.ps1` | rasterises an `.svg`/`.html` to PNG at an exact size (headless Chrome) |
| `Capture-Installer.ps1` | grabs the installer window into `tools/raw/` |
| `Compose-Installer.ps1` | `assets/installer.png` (window + English callouts) |
| `Compose-Screens.ps1` | `assets/before-after.png` from two raw chat captures |

Regenerate the artwork after adding a supported app:

```powershell
powershell -ExecutionPolicy Bypass -File tools\Build-Banner.ps1
powershell -ExecutionPolicy Bypass -File tools\Render-Assets.ps1
```

## Before / after

The point of this image is a **real assistant reply**, not a user message. A user message
is raw text with literal backticks and `white-space: pre-wrap`; an assistant reply is
rendered markdown with real `<code>`, `<ul>` and `<pre>` elements, which is what the patch
actually operates on. `test/bidi-harness.html` keeps those two surfaces separate for the
same reason.

The copy and the original share one account and one history, so the reply is typed **once**
and then photographed twice.

### 1. Ask for a reply with every structure in it

Send this to the patched copy. It is deliberately over-specified so the answer stays short
enough to fit one frame without scrolling:

```
ענה בעברית בקצרה מאוד ובפורמט הזה בדיוק, בלי כותרות ובלי הקדמה:
1) פסקה אחת קצרה על הפקודה `npm install` שמזכירה את המילה package באנגלית ומסתיימת בסימן שאלה.
2) רשימה של שתי נקודות, כל אחת עד שש מילים.
3) שורה אחת: 2 + 3 = 5
4) בלוק קוד bash של שלוש שורות.
```

The reply must contain all five: an RTL paragraph with an English word inside, real inline
code, a bullet list, a numeric expression, and a fenced code block. If it comes back too
long for one frame, ask again with a tighter limit. Never crop mid-sentence.

### 2. Capture both sides

Launch each app with a CDP port, take a full-viewport screenshot, and let the sidecar JSON
record the reply's rectangle in CSS pixels:

```powershell
# patched copy
$env:SAND_DISABLE_UPDATES='1'
Start-Process "$env:LOCALAPPDATA\RtlPatch\grokbot\copy\Grok Bot.exe" -ArgumentList '--remote-debugging-port=9222'
# ...capture, then close it and launch the ORIGINAL on another port
Start-Process "$env:LOCALAPPDATA\Programs\Grok Bot\Grok Bot.exe" -ArgumentList '--remote-debugging-port=9223'
```

Both apps share a single-instance lock, so only one may run at a time.

Before trusting the "before" frame, confirm the original really is unpatched:
`window.__codexRtlPatchVersion` must be `undefined` and `[data-codex-rtl]` must match zero
elements.

### 3. Compose

```powershell
powershell -ExecutionPolicy Bypass -File tools\Compose-Screens.ps1
```

The two apps can report different device pixel ratios, so the crop is defined in CSS pixels
and converted per image. That is what keeps both panels showing the identical region.

### Rules

* Crop to the reply. No sidebar, no avatar, no account name, no conversation list.
* Check every PNG for personal data before committing it.
* Same app build on both sides. State in the caption only what is actually true.

## Installer

```powershell
powershell -ExecutionPolicy Bypass -File tools\Capture-Installer.ps1 -OpenPicker -AppIndex 3 -SettleSeconds 25
powershell -ExecutionPolicy Bypass -File tools\Compose-Installer.ps1
```

`-OpenPicker` drops the app list open through `CB_SHOWDROPDOWN`, so nothing drives the mouse
or the keyboard.

The primary button's label follows this machine's real state: it reads "התקן" only when the
selected app has no patched copy yet, and "עדכן" once one exists. The published shot must show
"התקן", because the callout beside it says "Click Install". So before capturing, remove the RTL
copy of ONE app and point the picker at it with `-AppIndex` (0-based, in `Get-RtlAppIds` order:
codex, opencode, traycer, t3code, grokbot), then put the copy back:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\Uninstall-DesktopRtl.ps1 -App t3code
# ...capture...
powershell -ExecutionPolicy Bypass -File scripts\Install-DesktopRtl.ps1   -App t3code
```

Pick an app that is currently `UpToDate`, so reinstalling lands it back in exactly the state it
started from. Uninstall never touches the original app, only the patched copy. Reinstalling also
redeploys the agent runtime from the working tree, so do this from a tree whose engine files match
the released version.

### Gotchas worth remembering

* The capture process calls `SetProcessDPIAware()`. Without it `GetWindowRect` and
  `CopyFromScreen` disagree on a scaled display and the grab lands on some other window.
* `SetForegroundWindow` is blocked from a background process, so the window is pinned
  topmost instead. Close anything that would sit over it first.
* Crop to `DWMWA_EXTENDED_FRAME_BOUNDS`, not `GetWindowRect`: the latter reports the invisible
  resize border as well, which drags a strip of whatever sits behind the form into the grab.
  Only the form rectangle is captured; the dropdown paints inside it anyway.
* `CB_SETCURSEL` changes the selection silently. WinForms raises `SelectedIndexChanged` from the
  `CBN_SELCHANGE` notification its parent reflects back, so that has to be sent separately, and
  the window rectangle has to be re-read afterwards because switching apps relabels the form.
* `Start-Process -ArgumentList` mangles an absolute path when the repo sits under a
  non-ASCII directory, hence `-WorkingDirectory` plus a relative script path.
* The WinForms class name is `WindowsForms10.COMBOBOX...`, not `ComboBox`.

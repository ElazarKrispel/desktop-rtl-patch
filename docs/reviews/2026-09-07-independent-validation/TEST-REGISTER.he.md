# פנקס הרצות ומגבלות

תאריך: 2026-09-07. קוד מוצר בסיס 02cc70a; ראש ענף חומר הסקירה 3c48cc4. כל הרצות המוצר בשלב זה משתמשות רק בקבצי דמה או מחליפות גבולות מערכת. שום התקנה/הסרה אמיתית לא בוצעה. 'REPRODUCED' פירושו ששוחזר כשל, לא שהמוצר עבר בדיקת קבלה.

## בדיקות שבוצעו

| בדיקה | סביבה והיקף | תוצאה | ראיה |
|---|---|---|---|
| hash של חומר הסקירה | Git blobs, Python | 5 hashes תואמים; inventory של 10 קבצים; קוד מוצר ללא diff | [provenance-results.json](provenance-results.json) |
| PowerShell parse | 18 קובצי PS1 tracked; PS7.6.5 וגם Windows PS5.1.26100.9168 | אפס שגיאות בשניהם | [static-results.json](packaging/static-results.json), [static-ps51.json](packaging/static-ps51.json) |
| BOM/ASCII | בדיקת bytes, ללא הרצה | GUI/tray/settings/errors עם BOM; lib ו־Herdr ASCII | [static-results.json](packaging/static-results.json) |
| Node syntax | Node v24.14.0, payload ו־asar editor | שני --check סיימו exit0 | [static-ps51.json](packaging/static-ps51.json) |
| F01 CLI מלא | Node24, Windows, 5 מקרי קבצים סינתטיים | direct/prefix נדחו; normal/junction/hardlink שינו בייט; file symlink נוסף BLOCKED EPERM | [fuse-results.json](paths-state/fuse-results.json) |
| F01 wrapper מלא בגבול helper | PS5.1 -> Node CLI, junction סינתטי | verification 20 -> flip -> verification0, שינוי byte50 | [fuse-wrapper-results.json](paths-state/fuse-wrapper-results.json) |
| F01/F05/F06/F08/N05 | AST של פונקציות מקור, filesystem אמיתי וגבולות זיהוי/launch/network מדומים | 4 guards, 3 סבבי retry, 2 קידודים, quarantine, launch capture | [paths-state-results.json](paths-state/paths-state-results.json) |
| F08 environment | שני runspaces אמיתיים PS5.1, profiles סינתטיים | environment של A השתנה בעקבות B; פרופיל A לא השתנה | [runspace-env-results.json](paths-state/runspace-env-results.json) |
| F02/F03/F04/N01/N02/N03 | PS5.1, שש בדיקות assertion; נעילת Windows ומחיקת filesystem ב־F02/F03 אמיתיות | ששת תרחישי ה־baseline שוחזרו | [results.json](lifecycle/results.json) |
| F09 | payload אמיתי, Chrome152 headless בפרופיל חדש, Windows | 5 REPRODUCED, שתי בקרות PASS, אפס browserErrors | [renderer-results.json](renderer/renderer-results.json) |
| F10 packaging logic | PS5.1, build במבנה דמה, bootstrap עם stubs, helpers מקוריים | 5 REPRODUCED | [probe-packaging-results.json](packaging/probe-packaging-results.json), [build log](packaging/build-missing.log) |
| ZIP שפורסם | download בלבד, Python ZipFile בזיכרון, השוואה ל־Git blobs | checksum מדויק; 11 byte-identical, 27 LF/CRLF בלבד; אין חסר, 8 extras למדיניות build | [release-byte-validation.json](packaging/release-byte-validation.json) |
| ענפים, PRים ו־Actions | fetch/gh API לקריאה בלבד | main=baseline, PR8 פתוח, PR6/7 מוזגו, Actions=0 | [actions.json](packaging/actions.json), [provenance](provenance-results.json) |

## פקודות לשחזור

משורש checkout מבודד. ה־probes מצפים לקוד הבסיס; כמה מהם בודקים hash או מספרי שורות ונועדו להפסיק אם המקור השתנה. על תיקון מוצר יש להפוך את expected להתנהגות הרצויה במבחני regression נפרדים, ולא לשמר assertion שהתקלה חייבת לקרות.

```powershell
python docs/reviews/2026-09-07-independent-validation/verify-provenance.py
node --check scripts/lib/asar-edit.mjs
node --check src/desktop-rtl-patch.js
node docs/reviews/2026-09-07-independent-validation/paths-state/probe-fuse.mjs
powershell.exe -NoProfile -ExecutionPolicy Bypass -File docs/reviews/2026-09-07-independent-validation/paths-state/probe-paths-state.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File docs/reviews/2026-09-07-independent-validation/paths-state/probe-fuse-wrapper.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File docs/reviews/2026-09-07-independent-validation/paths-state/probe-runspace-env.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File docs/reviews/2026-09-07-independent-validation/lifecycle/Test-LifecycleEvidence.ps1
node docs/reviews/2026-09-07-independent-validation/renderer/probe-renderer.mjs
powershell.exe -NoProfile -File docs/reviews/2026-09-07-independent-validation/packaging/probe-packaging.ps1
python docs/reviews/2026-09-07-independent-validation/packaging/verify-release.py
```

יש תלות בסדר: probe-paths-state קורא fixture שנוצר ב־probe-fuse. probe-renderer דורש Chrome מקומי ואת רכיבי סביבת הבדיקה המפורטים בסקריפט, ואינו מתקין דפדפן. verify-release דורש את ZIP ו־SHA256SUMS.txt שהורדו ל־C:\rtl-audit-20260907-downloads. הורדתם לצורך השחזור:

```powershell
gh release download v2.5.0 --repo ElazarKrispel/desktop-rtl-patch --pattern desktop-rtl-patch-2.5.0.zip --pattern SHA256SUMS.txt --dir C:\rtl-audit-20260907-downloads
```

הסקריפטים שומרים תוצאות מחדש. אין להריץ במקביל שני עותקים של אותו probe משום שהם משתמשים בשם קבוע לקובץ התוצאה. scratch roots ייחודיים נשמרים ומוחרגים מ־Git. יש לקרוא את תנאי הבדיקה לפני הרצה מחדש, במיוחד אם שינו קוד מוצר או דרכי isolation.

## NOT RUN / BLOCKED

| בדיקה שלא בוצעה | סיבה | דרישה להמשך |
|---|---|---|
| כל מחזור install/update/uninstall/reinstall אמיתי | מחוץ להרשאה בשלב הראשון | VM/חשבון בדיקה ואישור לפעולות החיות |
| GUI/tray/settings חיים או SelfTest שלהם | עלולים לטעון discovery/state/process APIs ללא בידוד מלא; אין צורך בשביל שחזורי AST | host בדיקה עם roots/Registry/events מבודדים |
| test/renderer-injection.harness.ps1 המלא | נבדק בקוד אך uninstall מגיע ל־Registry/process APIs; בידוד env/shortcuts לבדו אינו מספיק להנחיית המשתמש | PR-00, לא לייחס לו את מספר הבדיקות שדווח ב־PR6 |
| file symlink Windows | EPERM; לא התבקשה העלאת הרשאות | מכונת בדיקה בעלת יכולת symlink, בלי לשנות מדיניות המחשב הנוכחי |
| TOCTOU/root replacement וכל mirror/swap/delete | לא כוסה ב־junction/fuse probe | PR-04 acceptance מלא |
| Registry provider אמיתי עם foreign siblings | בדיקת N01 השתמשה בזיכרון בלבד | hive/keys בדיקה ייעודיים בלבד |
| N04 worker quit/restart/self-update | לא הורץ lifecycle של תהליכי מוצר | host/event names ייחודיים, injection checkpoints |
| WSH+shortcut עם שם משתמש עברי | נבדקו bytes ובקשות בלבד | recorder executable וסביבת משתמש מבודדת |
| React/applcation streaming/selection/undo/IME | fixture DOM אינו היישום האמיתי | PR-09 עם framework וגרסאות יעד נבחרות |
| code signing, signed updates, adversarial ZIP extraction, ARM64, Windows10 | לא נבדקו בשלב הנוכחי | תכנית release/support מאושרת |
| benchmarks והשוואת UI frameworks | אינם נחוצים כדי לאמת מנוע; לא נבנה GUI | מדידה מוגדרת ב־vertical slice אחד |

## כשלים של כלי הבדיקה

probe-fuse נכשל בתחילה בגלל עומק path שגוי לקובץ העורך, תוקן ונבדק מחדש עם בקרות exit; הראיה הראשונה נשמרת בשם [harness-error-fuse-initial.json](paths-state/harness-error-fuse-initial.json). ב־packaging תוקנו scope של לכידת בקשות ושם root של ZIP לפני ריצה סופית. אלה כשלים בבדיקות ולא ממצאי מוצר.

ניקוי תיקיות זמניות של lifecycle ושל Chrome נדחה אוטומטית עם `blocked by policy`, ללא פירוט. לא בוצע ניסיון לעקוף את המחיקה שנדחתה. התיקיות נשארו בעץ האימות בלבד ומוחרגות ב־.gitignore. הבדיקות אינן כוללות נתונים של פרופילי משתמש מקוריים.

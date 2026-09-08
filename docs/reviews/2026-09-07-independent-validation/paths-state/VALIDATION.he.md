# אימות עצמאי: נתיבים, retry, launchers ו-state

תאריך: 2026-09-07. קוד המוצר שנבדק: `02cc70a8b750de4bc88b740cf8a64f292a5c0325`. נקראו חבילת הסקירה המלאה, כל ארבעת קובצי הראיות והוראות CLAUDE המקומיות. חומר הסקירה והוראות מקומיות לא נערכו. לא השתנה קוד מוצר.

סביבה: Windows NT 10.0.26200.0, Windows PowerShell 5.1.26100.9168, Node v24.14.0. `PASS` להלן משמעו שהשחזור הצפוי התקבל, ולא שהמוצר תקין. אין בדיקות E2E של אפליקציות אמיתיות. כל קובצי הדמה, כולל מטרות הקישורים, נמצאים בתיקיות ייחודיות בבעלות הבדיקה. אין Registry, קיצורים או named events. תהליכי הילד היחידים שהופעלו ב-probes הם PowerShell ו-Node לצורך הבדיקות.

## F01: מאומת, בגבול מדויק יותר מן הראיה המקורית

**עובדה בקוד:** `scripts/lib/desktop-rtl-lib.ps1:662-676` בודקת `GetFullPath` ו-prefix עם מפריד; `2489-2507` עושה אותו דבר למבחן בעלות. `scripts/lib/asar-edit.mjs:112-139` משתמש ב-`path.resolve`, פותח שוב לפי שם באמצעות `fs.openSync(...,'r+')` וכותב בייט. אין פתרון יעד פיזי או בדיקת מספר hard links.

**מסלול קורא:** `Invoke-CodexRtlUpdate`, שורות `1984-2082`, בונה/מרענן staging; עבור ASAR, `2074-2076` קוראת ל-`Assert-RtlAsarFuseOff`. זו מבצעת `fusestate`, guard, `fuseoff --root Profile.Staging`, ואימות חוזר (`831-861`). `Invoke-RtlNodeCli:811-824` מפעילה את עורך ה-ASAR. `Invoke-Robocopy:1130-1134` משתמשת ב-`/MIR`; לא הוכח כיצד כל קומבינציית קישורים שורדת או נוצרת בזרימת ההעתקה. זה נשאר מבחן נוסף, ולא הוכחת ניצול של כל מתקין.

**מפת משטחים רלוונטיים:** ASAR inject `1142-1156`, config חי `1162-1212`, הזרקת dir `1348-1350`, inline `1413`, ופענוח בעלות shell/process `2489-2624` נשענים על בדיקות לקסיקליות. כתיבת state/config `198/750`, mirror `2047`, יצירת staging/sentinel `2037-2040`, הסרת קבצים ב-copy `2051-2053`, והסרת Herdr staging `desktop-rtl-herdr.ps1:225-229` אינם כולם עוברים דרך אותו guard. לפיכך אין לאמץ את הערת הקוד "Every engine write path calls this" כהוכחה להיקף הגנה מלא. כתיבת ה-ASAR משתמשת גם בקובץ זמני והחלפה; אין להסיק מתוצאת fuseoff שכל סוג כתיבה דרך hard link מתנהג כמוהו.

**שחזור Windows:** [probe-fuse.mjs](probe-fuse.mjs) מריץ את `asar-edit.mjs` המלא, ללא חילוץ הפונקציה. יעד חיצוני ישיר ו-prefix דומה נדחו בקוד 22 ונשארו זהים. קובץ פנימי תקין השתנה בבייט 50. junction פנימי המפנה לתיקייה חיצונית ו-hard link פנימי לקובץ חיצוני שינו שניהם את אותו בייט ביעד הפיזי החיצוני, קוד 0. "חיצוני" פירושו מחוץ ל-staging הסינתטי, עדיין בתוך fixture בטוח. [fuse-results.json](fuse-results.json).

**בדיקת שרשרת נוספת:** [probe-fuse-wrapper.ps1](probe-fuse-wrapper.ps1) טוען גופי פונקציות AST מקוריים של wrapper, guard ו-Node runner ומפעיל את עורך המוצר המלא. `fusestate=20 -> flip -> fusestate=0`; היעד דרך junction השתנה בבייט 50. [fuse-wrapper-results.json](fuse-wrapper-results.json). זו ראיה חזקה יותר מפונקציה מבודדת, אך אינה מסלול התקנה מלא.

**חסר:** file symlink ב-Windows: `BLOCKED EPERM`; לא בוצעה העלאת הרשאות. root שהוחלף לאחר בדיקה, TOCTOU, נתיבי רשת, וכל מסלול mirror/swap/delete: `NOT RUN`. הראיה המקורית ב-PR נשארת Linux עם פונקציה שחולצה, ללא הרחבת הטענה שלה בדיעבד. בהרצה הראשונה של probe החדש הייתה שגיאת עומק נתיב בעזר הבדיקה, וכל ילדי Node נכשלו בטעינת המודול. היא תוקנה והתווספו בקרת קיום עורך ובקרות exit. [harness-error-fuse-initial.json](harness-error-fuse-initial.json) נשמר כשגיאת harness, לא כתוצאת מוצר.

**השפעה וביטחון:** ביטחון גבוה מאוד שה-guard אינו מבטיח copy-only מול links. התנאים ליצירת/החלפת link בתוך עץ המוצר בפועל ומודל התוקף לא אומתו; אין טענת privilege escalation.

**המלצה:** PR ייעודי לכתיבות ומחיקות: שורשים בבעלות המנוע, מדיניות reparse components, זהות קבצים ומספר קישורים לפני שינוי במקום, ותחימת פעולות על handle כשנדרש. לא להסתפק ב-`realpath` חד-פעמי, לא לחסום symlink של מקור Herdr רק משום שהוא קישור לקריאה, ולא להכניס hard links של קבצים משתנים מהמקור כאופטימיזציה. יש להגדיר במפורש אם ההגנה אמורה להתמודד גם עם החלפה עוינת במקביל תחת אותו משתמש.

## F05: מאומת במסלול המנוע, עם רשת מדומה

**מקורות:** הורדה ואחיזת חריגה תחת `[ARTIFACT]`: `desktop-rtl-herdr.ps1:137-191`, ובפרט `165-174`; שרשרת `Invoke-HerdrRtlBuild:220-245 -> Invoke-HerdrRtlInstall:533-607 -> Invoke-CodexRtlUpdate:1943-1951`. סיווג וסף: `desktop-rtl-lib.ps1:1804-1854`; guard לפני הורדה: `1926-1939`; catch רושם block: `2139-2141`. המגש מפעיל `-Auto` מתוך worker ב-`DesktopRtlTray.ps1:405-440`; Watch CLI עושה זאת ב-`desktop-rtl-lib.ps1:2191` וב-poll שאחריו.

**שחזור:** [probe-paths-state.ps1](probe-paths-state.ps1) משתמש בגופי AST מקוריים של כל שרשרת המנוע עד downloader. זיהוי source, lock, logging, running-check ורשת מדומים. שתי קריאות מורידות זורקות `WebException Timeout`. לאחר הראשונה count=1 ולא חסום; לאחר השנייה count=2 וחסום. בפעם השלישית הסימולציה מסמנת רשת תקינה אך downloader אינו נקרא כלל. החסימה נשארת והפעולה חוזרת ללא exception. [paths-state-results.json](paths-state-results.json), `F05`.

**השפעה וביטחון:** ביטחון גבוה מאוד. אירוע רשת שנמשך שני סבבי poll מספיק כדי למנוע התאוששות אוטומטית באותה חתימה/גרסת כלי. Force יכול לעקוף והחלפת חתימה/גרסת כלי מיישנת block; לכן זו חסימה מתמשכת בתנאים מוגדרים, לא "לעולם". המסלול קיים גם כשה-source נשאר מותקן.

**חסר:** שרת HTTP עם timeout אמיתי, 429 ו-Retry-After, הורדה חלקית והחלמה עד copy עובד: `NOT RUN`. בדיקת checksum פגום וסיום מוצלח של התקנה לא הורצו כאן. ה-stub הבריא מכוון להיכשל אם יגיעו אליו, ולכן הראיה היא היעדר ניסיון שלישי, לא הורדה בריאה שהצליחה.

**המלצה:** להפריד Network/Timeout/RateLimit מכשל artifact מבני ו-integrity; לשמור סף מבני מוגבל ולהוסיף `nextAttemptAt` זמני. כללי Force הנוכחיים ראויים לשימור: הם עוקפים block אבל אינם מוחקים אותו לפני הצלחה. אותו PR צריך בדיקת שתי תקלות ואז החלמה אמיתית בסביבה מבודדת.

## F06: מאומת עבור VBS; אין לשנות את Herdr ללא צורך

**מקורות:** Grok Bot הוא הפרופיל עם `LaunchEnv` בשורה `495` בליבה; `New-RtlLaunchScript:1537-1574` כותבת exe/workdir מוטמעים עם `ASCIIEncoding` ב-`1571`. `New-RtlShortcut:1598-1607` מפנה ל-VBS הזה. כפתורי Open מהמגש/אשף משתמשים ב-`Start-RtlCopyApp:886-911`, ולכן אינם עוברים באותה כתיבת VBS.

**שחזור:** נוצר profile סינתטי עם אותו חוזה LaunchEnv ונתיב הכולל `אבג copy space`. ב-VBS הוחלף החלק העברי ב-`??? copy space`. זו השחתת בתים ודאית, ולא תלות בהתנהגות WSH. הרצת launcher/קיצור לא בוצעה. `F06` ב-[paths-state-results.json](paths-state-results.json).

**הבחנה:** `New-HerdrRtlLauncher`, `desktop-rtl-herdr.ps1:415-456`, כבר כותבת UTF-8 ללא BOM עם `@chcp 65001 >nul` בשורה הראשונה. אותו fixture שמר את העברית בדיוק. אין לפתוח תיקון ASCII ל-Herdr CMD: הוא אינו סובל מהטענה הזאת בקוד הנוכחי.

**השפעה וביטחון:** ביטחון גבוה מאוד ב-lossy VBS. כשל פתיחה מקיצור Grok תחת נתיב עברי הוא הסקה חזקה; opening דרך tray/GUI יכול להתנהג אחרת מאחר שהוא משתמש במסלול אחר.

**חסר:** WSH בפועל עם placeholder program בטוח, argv/env/cwd, Windows Terminal, OneDrive והפניית תיקיות, desktop shortcut ב-profile נקי: `NOT RUN`.

**המלצה:** תיקון זמני ממוקד לפורמט Unicode הנקרא ב-WSH, עם בדיקת WSH ולא רק file contents. בהמשך לעבור לחוזה Launch אחד שמוסר path/args/env כמבנה, לשימוש גם במנהל וגם בקיצורים; אין צורך לשכתב GUI עבור תיקון קידוד.

## F08: מאומת בתתי-טענות; race של אפליקציה חיה עדיין לא הוכח

**Status:** `Read-RtlState:172-175` מחזירה null בכשל JSON; `Get-CodexRtlStatus:1861-1869` מעבירה את הקובץ ל-`.bad`, ללא action lock ועם Force. fixture של JSON פגום הועבר בפועל. זה סותר status טהור ומאפשר החלפת evidence קודמת באותו `.bad`. נתיב קיים עם תוכן ריק אינו עובר אותו quarantine. קוראים: אשף `278`, Settings `209`, מגש `557`.

**אטומיות:** `Write-RtlState:177-200`, `Write-RtlConfig:746-752` ו-`Set-RtlBlocked:1829-1836` כותבות ישירות ב-WriteAllText. זו עובדה סטטית; לא הורגנו כותב באמצע כדי לטעון שאובדן נתונים שוחזר. state מגיע משני מסלולי הצלחת install, בליבה `2124` וב-Herdr `595`; config מגיע מ-Settings `208`. לעומתן `Write-RtlAgentConfig:2413-2429` כבר נעולה ומשתמשת ב-temp/Replace/backup. אין לבנות מנגנון agent atomic חדש; יש להכליל את התבנית בזהירות.

**Environment:** `Set-RtlActiveApp:574-625` מפרידה script globals לפי runspace אבל משנה process env בשורות `615-620`. המגש מפעיל worker runspace ב-`405-440` ועדיין מאפשר פתיחת app ב-`244/583`, פענוח סטטוס ובניית watchers. `Invoke-AppAction:209-223` שומרת ומשחזרת env; זה מגן על סדר טורי, לא על זמני ביניים של worker. `Start-RtlCopyApp:890-909` מסירה Electron flags ומשנה LaunchEnv סביב Start-Process, ולכן גם היא משתפת חלון זמן עם כל child process אחר. `Invoke-RtlNodeCli:818` יורשת את env הזה. worker באשף נוצר ב-`Install-DesktopRtlGui.ps1:355-378`.

**שחזור ממוקד:** שני runspaces אמיתיים, גוף selector מקורי ופרופילים סינתטיים. A בוחר electron-as-node ורואה flags=1; B בוחר פרופיל אחר; A עדיין מחזיק ActiveProfile של Electron אך שני flags שלו null. [probe-runspace-env.ps1](probe-runspace-env.ps1), [runspace-env-results.json](runspace-env-results.json). זו הוכחה לשיתוף ודריסה אפשרית, באינטרליבינג מבוקר. היא אינה כשל אמיתי של Tray/OpenCode או מדידת שכיחות race.

**השפעה וביטחון:** גבוה מאוד בתופעות הישירות; בינוני לגבי כשל app חי בתזמון הנוכחי. סטטוס יכול לשנות את ראיות הכשל, interruption עלול לפגום JSON, ותהליך ילד יכול לקבל flags שאינם מתאימים לתפקידו. חומרת env אינה מצדיקה להקדים שכתוב כל ה-globals לפני הגנת נתונים, אך child env מפורש מתאים לתיקון מוקדם ממוקד.

**המלצה:** quarantine רק בפעולה נעולה; כתיבת state/config/block באמצעות helper אטומי עם schema/backup/handling שמוגדרים; `ProcessStartInfo.EnvironmentVariables` לפי סוג child ולא mutation של env כלל-תהליכי. AppContext מלא יכול לבוא ב-PR ארכיטקטורה מאוחר יותר. crash/restart, state migration ו-race במהלך editor/launch אמיתי: `NOT RUN`.

## N03: כיוון החקירה אומת ברמת ה-helper

עם block תקף count=2 ו-state פגום ללא exe, הקריאה ל-Get-CodexRtlStatus החזירה `Fresh`, ו-`BlockedError=null`, בעוד `Test-RtlUpdateBlocked` נשאר true. זאת קדימות `1887-1889`, לא סתירה בתנאי החסימה. UI פתוח עם המצבים האלה לא הורץ. ההמלצה היא ממדי מצב נפרדים להתקנה ולעדכון, לא החלפת כל Fresh ב-Blocked באופן גורף.

## N05 חדש: פתיחת Herdr מהמנהל עוקפת בידוד נתונים

**עובדה מאומתת בתכנון launch:** Herdr profile מכריז `LaunchEnv=$null` ב-`desktop-rtl-lib.ps1:552` כי סביבתו נמצאת ב-CMD. `New-HerdrRtlLauncher:430-432` מכניסה XDG_CONFIG_HOME, XDG_STATE_HOME ו-HERDR_BIN_PATH. אבל `Start-RtlCopyApp:886-911` אינה מסתעפת לפי prebuilt ומפעילה exe ישירות. האשף `503`, המגש `244/583` ו-Settings `225` קוראים לה.

**בדיקה בטוחה:** Start-Process הוחלף ב-capture stub; קובץ `herdr.exe` הוא טקסט שאינו executable. לאחר ניקוי שלושת משתני XDG/Herdr בתהליך הבדיקה, בקשת Open הייתה `herdr.exe` עם שלושתם null, והפונקציה החזירה true. לעומתה, טקסט ה-CMD שנוצר כולל את ההגדרות. `N05HerdrOpen` ב-[paths-state-results.json](paths-state-results.json).

**הסקה:** בהסתמך על חוזה Herdr המתועד בפרויקט, פתיחה רגילה מה-GUI/tray יכולה להשתמש בפרופיל ברירת מחדל של המקור במקום בפרופיל הפרטי. לא נפתח Herdr ולא נקרא או השתנה פרופיל אמיתי; תוצאת runtime וזהות session חסרות עדיין. אין לטעון שהושחת מידע בפועל.

**המלצה:** להכניס תיקון זה לחבילת הגנת נתוני Herdr: פונקציית Launch מתאימה ל-adapter, זהה למגש/אשף/קיצור; terminal host ו-XDG מתאימים בכל מסלול. תנאי קבלה: recorder executable מבודד ל-cwd/argv/env משלושת מסלולי UI, ואחר כך בדיקה חיה רק באישור. תווית "ניסיוני" אינה פותרת את הפער בין חוזה פרטיות לבין launch path.

## רצף PRים מומלץ לתחום זה

1. מדיניות נתונים + launch isolation של Herdr, עם fixtures שמוודאים XDG ומסלול reinstall; תלוי בבעלות על תכנון F03. אין צורך בבחירת UI stack. rollback חייב לשמור את הנתונים, לא להשיב מסלול מחיקה מסוכן.
2. שורשים/זהות קבצים וגבולות כתיבה F01, בנפרד משינוי receipt. קבלה: הבדיקות כאן משתנות מסירוב חסר לסירוב מפורש; כל יעד אסור byte-identical; controls פנימיים ממשיכים לעבוד. regression per adapter, לרבות Herdr source symlink לקריאה בלבד. rollback: לבטל פעולת patch שנפגעה או להשאיר adapter חסום; לא להחזיר guard לקסיקלי במסווה של rollback בטוח.
3. retry classification F05 + קידוד VBS F06, PRים קטנים ועצמאיים שאפשר לקדם במקביל בלי לערוך אותם contract files באופן סותר. אין הרחבת הורדות/ארכיטקטורות ב-PR retry. rollback שומר schema תאימות ו-blocks מבניים.
4. בסיס atomic state/status טהור ביחד עם lifecycle receipt, כך ש-CleanupPending לא ייכתב ישירות לקובץ בר-קריעה. migration/backups ו-failure injection הם תנאי קבלה; חזרה לגרסה הקודמת חייבת לכבד schema חדש או להציג חוסר תאימות.
5. child environment מפורש וחוזה Launch. קודם child env + recorder fixtures; בהמשך AppContext רחב ומעבר UI. אין צורך בשכתוב המנוע כדי לסגור פער env נקודתי.

## שחזור הבדיקות

להריץ משורש checkout מבודד שבו קוד המוצר תואם SHA המוצהר. סדר חשוב: probe PowerShell הראשי משתמש ב-fixture שנוצר ב-probe Node. אין להפעיל harnesses קיימים במוצר ללא ביקורת בידוד נוספת.

```powershell
node docs/reviews/2026-09-07-independent-validation/paths-state/probe-fuse.mjs
powershell.exe -NoProfile -ExecutionPolicy Bypass -File docs/reviews/2026-09-07-independent-validation/paths-state/probe-paths-state.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File docs/reviews/2026-09-07-independent-validation/paths-state/probe-fuse-wrapper.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File docs/reviews/2026-09-07-independent-validation/paths-state/probe-runspace-env.ps1
```

Fixtures נשמרים כדי להימנע ממחיקה רקורסיבית חוצה junction בטעות; `.gitignore` המקומי מונע הכנסתם לתיעוד. scripts ו-results מסוננים הם הראיות הניידות. אף אחת מבדיקות אלה אינה אישור לשינוי התקנות, הפעלת אפליקציות, merge או release.

# פנקס אימות עצמאי: F01-F10

קוד נבדק: `02cc70a8b750de4bc88b740cf8a64f292a5c0325`, זהה לקוד המוצר בראש PR #8 וב־origin/main בזמן הבדיקה. אין תיקוני מוצר בשלב הזה. 'מאומת' משמעו שהטענה בגבול הראיה נכונה בקוד הנוכחי; אין פירושו שתיקון עבר או שכל מסלול Windows נבדק. 'נכון חלקית' משמש לממצא שמשלב התנהגות מוכחת וסיכון שטרם נמדד.

לכל שחזור יש fixture ולוג בתיקיית התחום. [מפת הרצות](TEST-REGISTER.he.md) מקשרת לפקודות ולתוצאות. מקורות מפורטים: [lifecycle](lifecycle/FINDINGS.he.md), [נתיבים/state](paths-state/VALIDATION.he.md), [renderer](renderer/NOTES.he.md), [packaging](packaging/NOTES.he.md). אלה חלק מהפנקס, לא נספחי רשות.

## תמונת מצב

| ID | סיווג | הראיה החזקה ביותר | החלטת טיפול |
|---|---|---|---|
| F01 | מאומת בגבול write guard | wrapper PowerShell ועורך Node מלא משנים יעד דרך junction סינתטי ב־Windows | חסם הבטחת copy-only, PR-04 |
| F02 | מאומת | מחיקת exe/state לצד non-exe נעול שנותר, ואז enumeration ריק | חסם התאוששות עצמאית, PR-02 |
| F03 | מאומת | מחיקת config/session סינתטיים בהסרת Herdr רגילה | חסם נתונים, PR-01 |
| F04 | מאומת, חלק מהטיפול כבר קיים | update ב־lock=false מחזיר ללא תוצאה; מסלול GUI מסמן Ok בקוד ללא בדיקת התוצאה, GUI לא הורץ | להשלים תוצאות בכל consumers, PR-02/03 |
| F05 | מאומת בתנאי חתימה/גרסה קבועות | שני timeouts מדומים, ואז אין ניסיון שלישי לאחר חזרת הרשת | לתקן סיווג בלי להסיר latch, PR-05 |
| F06 | מאומת ל־Grok VBS | נתיב עברי הופך ל־??? בקובץ שנוצר | תיקון קידוד ממוקד, PR-06 |
| F07 | מאומת | README מול קוד, metadata ובתי ZIP שנבדקו | גילוי מדויק לפני קידום, PR-07 |
| F08 | נכון חלקית כממצא מורכב | status מזיז JSON; runspaces דורסים environment בתזמון מבוקר; כתיבות ישירות בקוד | atomic/status מוקדם, context מלא מאוחר, PR-02/08 |
| F09 | מאומת בתתי־טענות DOM; כשל framework לא אומת | payload אמיתי ב־Chrome, חמישה תרחישי התנהגות | תיקונים ממוקדים לפני בטא, PR-09 |
| F10 | מאומת בפערי build/update; אימות ZIP נוסף הושלם | build חסר מצליח; בחירת ZIP/שם checksum/fallback; ZIP אמיתי נבדק | שער release ובדיקות, PR-00/07 |

לא נמצא ממצא F שלם שכבר תוקן מעבר לבסיס. יש רכיבים שתוקנו קודם וראוי לשמר: Partial ב־GUI/CLI, שני כישלונות לפני latch, Force שאינו מוחק block לפני הצלחה, קידוד CMD של Herdr ואירוע quit ייחודי בבדיקה הישנה. אין לפתוח עבורם תיקון כפול.

## F01: גבולות כתיבה פיזיים

**עובדה:** [Assert-RtlWriteAllowed:662](https://github.com/ElazarKrispel/desktop-rtl-patch/blob/02cc70a8b750de4bc88b740cf8a64f292a5c0325/scripts/lib/desktop-rtl-lib.ps1#L662), canonical/ownership ב־2489-2507 ו־[doFuseOff:112](https://github.com/ElazarKrispel/desktop-rtl-patch/blob/02cc70a8b750de4bc88b740cf8a64f292a5c0325/scripts/lib/asar-edit.mjs#L112) בודקים שם נתיב. wrapper ב־831-861 מפעיל guard לפני שינוי fuse. ה־guard אינו משותף לכל מחיקה, mirror וכתיבת state; מפת המשטחים נמצאת במסמך התחום.

**ראיה:** עורך המוצר המלא דוחה יעד ישיר ו־prefix דומה, exit 22, ללא שינוי. junction ו־hard link בתוך root סינתטי מאפשרים שינוי בייט 50 ביעד מחוצה לו. גם שרשרת wrapper -> Node -> post-verify עוברת דרך junction. ביטחון גבוה מאוד בהתנהגות הזאת. מקור הראיה הישן נשאר Linux/extracted function בלבד.

**השפעה והסקה:** ההבטחה שלא ייכתב מחוץ ל־copy/staging אינה נאכפת פיזית במקרים האלה. לא הוכח שמסלול העתקה רגיל יוצר את התנאים, ולא הוכחו ניצול או העלאת הרשאות.

**חסר:** file symlink מסומן BLOCKED/EPERM. root replacement, TOCTOU, שרשרת robocopy/swap/delete מלאה ונתיבי רשת NOT RUN. **המלצה:** מדיניות reparse ו־hard links לפי סוג פעולה, שורשים שנגזרים מהפרופיל ומבדיקות בעלות, והגנת handle אם נדרש לעמוד בהחלפה מקבילה. receipt או realpath חד־פעמי אינם הרשאת מחיקה. מקור Herdr יכול להיות symlink לקריאה; אין לחסום אותו יחד עם יעדי כתיבה.

## F02: הסרה חלקית ואובדן יכולת ניהול

**עובדה:** [Uninstall:2942-2970](https://github.com/ElazarKrispel/desktop-rtl-patch/blob/02cc70a8b750de4bc88b740cf8a64f292a5c0325/scripts/lib/desktop-rtl-lib.ps1#L2942) ממשיך למחוק קיצורים ו־state אחרי כשל tree delete. Get-RtlInstalledApps:2475-2485 מונה לפי exe. הקוראים וקדימות מצבי ה־GUI מפורטים ב־lifecycle.

**ראיה:** FileStream אמיתי נועל non-exe ב־fixture Windows. מחיקת הקבצים אמיתית, וגבולות registry/process/locks מדומים. Certain=false, leftover אחד; exe/state/config וקיצור טקסט פיקטיבי נמחקו, הקובץ הנעול נשאר, ורשימת האפליקציות לאחר מכן ריקה. ביטחון גבוה מאוד במסלול filesystem ו־enumeration.

**השפעה:** המשתמש עלול לא לראות דרך להשלים הסרה, במיוחד אחרי restart ובהיעדר המקור. ה־GUI/CLI יודעים כבר להציג PARTIAL, אך זה אינו שומר את הניהול לאחר סגירתם. **חסר:** restart של GUI/tray, השלמת ניקוי דרך ממשק ותרחיש אפליקציה אחרונה מלא NOT RUN.

**המלצה:** receipt מינימלי גרסאי ואטומי עם uninstall intent ושאריות; enumeration לפי receipt ובעלות ולא exe בלבד. אין auto-repatch של CleanupPending. לשמור config ניהולי נחוץ עד סיום ולשמור מידע משתמש בנפרד. migration ממצב ישן צריכה להתבסס על roots ידועים ולא על נתיב חופשי שמופיע ב־JSON.

## F03: מדיניות נתוני Herdr

**עובדה:** [Uninstall:2955-2970](https://github.com/ElazarKrispel/desktop-rtl-patch/blob/02cc70a8b750de4bc88b740cf8a64f292a5c0325/scripts/lib/desktop-rtl-lib.ps1#L2955) מוחק data/state ב־prebuilt. אלה config/session פרטיים לפי herdr:291-292,415-453. האשף נותן הודעת שימור כללית לפרופיל משותף. CLI ב־Uninstall-DesktopRtl.ps1:41-45 מוחק StateDir כולו עם PurgeLogs, ולכן שינוי הרשימה במנוע בלבד אינו מספיק.

**ראיה:** הסרה ללא flags מחקה config/session/state סינתטיים, Certain=true. ביטחון גבוה מאוד במחיקה; לא הושמד פרופיל אמיתי. **השפעה:** אובדן הגדרות/session שהמשתמש מצפה לשמור, ללא הסכמה מתאימה.

**חסר:** reinstall עם config מותאם ומעקב session פעיל, GUI הודעת הסכמה אמיתית, runtime פרטי לעומת משותף NOT RUN. **המלצה:** שמירת מידע כברירת מחדל, PurgeLogs מוגבל ללוגים, בלי purge חדש בחבילה הראשונה. UI/CLI זהים במדיניות. לשלב N05 כדי שגם פתיחה תכבד את הפרטיות. לא לגעת במחיקת פרופיל Codex משותף.

## F04: תוצאות פעולות

**עובדה:** [Update:1900](https://github.com/ElazarKrispel/desktop-rtl-patch/blob/02cc70a8b750de4bc88b740cf8a64f292a5c0325/scripts/lib/desktop-rtl-lib.ps1#L1900) חוזר ללא תוצאה כשה־lock אינו נלקח; callsites ומסלול Success באשף מפורטים ב־lifecycle. Start-AppUninstall במגש מפעיל PowerShell מוסתר ללא ערוץ completion. בניגוד להכללה אפשרית, GUI/CLI להסרה כבר בודקים Certain/Leftovers.

**ראיה:** update עם lock boundary שמחזיר false מפיק אפס אובייקטים ללא exception. ביטחון גבוה ב־return path, בינוני בהשלכה על תצוגה שלא הורצה. Enter-RtlLock:204-209 מחזיר false על כל exception, כך שלא כל false הוא Busy; AccessDenied מחייב Failed/LockUnavailable.

**השפעה:** התקדמות/הצלחה אינן משקפות בהכרח פעולה שנעשתה; עובד רקע יכול להיכשל בלי הודעה מסיימת. **חסר:** נעילת OS בתהליך נפרד, לחיצה ב־GUI, קריסת worker ו־result retrieval אחרי restart NOT RUN.

**המלצה:** envelope גרסאי לכל תוצאה ו־exit code מתועד, operationId, appId, status, reason, leftovers ו־nextAction. להבדיל גם PreparedWaitingForClose מ־DeferredUnprepared: Electron מכין staging לפני המתנה, Herdr חוזר לפני build. אין להציג 'מוכן להחלה' בכל Deferred. מצב terminal נשמר לדיווח אחרי שהמנהל נסגר. N02 שייך לאותו חוזה בריאות.

## F05: תקלה זמנית הופכת לחסימה

**עובדה:** [Herdr download:165-174](https://github.com/ElazarKrispel/desktop-rtl-patch/blob/02cc70a8b750de4bc88b740cf8a64f292a5c0325/scripts/lib/desktop-rtl-herdr.ps1#L165) ממפה timeout ל־ARTIFACT. lib:1852-1855 מסווג ל־latch, catch:2139-2141 רושם ו־guard:1926-1939 עוצר Auto לאחר הסף.

**ראיה:** שרשרת AST מקורית עד downloader: timeout ראשון count1, שני count2, שלישי עם מצב רשת 'בריא' אינו קורא לרשת. ביטחון גבוה מאוד בסיווג ובחסימת הניסיון. ה־stub הבריא לא הוריד חבילה; לא הוכחה התקנה מוצלחת.

**השפעה:** auto-update אינו מתאושש ללא Force/שינוי חתימה/גרסה, בתנאים האלה. **חסר:** HTTP אמיתי עם timeout/429, Retry-After, checksum פגום והשלמת התאוששות מבודדת NOT RUN. **המלצה:** typed reasons, nextAttemptAt עם backoff/תקציב/jitter, חסימה לכשל מבני ואימות שנכשל; לשמור את ההגנה מפני סערת העתקות ואת סמנטיקת Force הקיימת.

## F06: קידוד נתיבי launch

**עובדה:** [New-RtlLaunchScript:1537-1574](https://github.com/ElazarKrispel/desktop-rtl-patch/blob/02cc70a8b750de4bc88b740cf8a64f292a5c0325/scripts/lib/desktop-rtl-lib.ps1#L1537) מטמיעה exe/workdir ב־ASCII. Grok profile:495 וקיצור:1598-1607 משתמשים בה. הפתיחה הישירה דרך המנהל היא מסלול אחר.

**ראיה:** עברית הפכה ל־??? בקובץ VBS. ביטחון גבוה מאוד בהשחתת הבתים. בקרה: CMD של Herdr שומר עברית עם UTF-8 ו־chcp 65001; הוא אינו דורש תיקון בגין F06. **השפעה:** פתיחה מקיצור תחת נתיב עברי עשויה להיכשל גם אם Open במגש עובד.

**חסר:** WSH/shortcut/argv/env בפועל, משתמש עברי, OneDrive ו־redirected folders NOT RUN. **המלצה:** Unicode נתמך ב־WSH כפתרון קצר עם executable recorder בטוח; launch contract משותף בהמשך. אין הצדקה להמתין ל־GUI חדש.

## F07: הבטחות תיעוד

**עובדה:** [README:225](https://github.com/ElazarKrispel/desktop-rtl-patch/blob/02cc70a8b750de4bc88b740cf8a64f292a5c0325/README.md#L225),329-330 מול fuse flip; 97,346 מול Herdr פרטית; 393 מול fork; 23 מול גודל ZIP; 152,184 מול bootstrap fallback. הפירוט המלא ב־packaging/NOTES.

**ראיה:** קריאת קוד, מסמך ובתי archive; ביטחון גבוה. **השפעה:** הסכמה לא מדויקת והנחות שגויות לגבי נתונים, אימות והיקף התאימות. **חסר:** ניסוי הבנת טקסט עם משתמשים ובדיקת notices של Herdr NOT RUN. **המלצה:** טבלה קצרה לכל adapter וטקסט אחיד ב־README, GUI ו־release notes; לא להבטיח תאימות לכל גרסה ולא להציג פרטיות משותפת כגורפת. אין מסקנה משפטית במסגרת האימות.

## F08: state ו־environment

**עובדה:** [Status:1861-1869](https://github.com/ElazarKrispel/desktop-rtl-patch/blob/02cc70a8b750de4bc88b740cf8a64f292a5c0325/scripts/lib/desktop-rtl-lib.ps1#L1861) מעביר state פגום ל־.bad; Write-RtlState:177-200, Write-RtlConfig:746-752 ו־Set-RtlBlocked:1829-1836 כותבים ישירות. agent config:2413-2429 כבר אטומי. Set-RtlActiveApp:615-620 משנה env תהליכי; Node runner:818 יורש אותו; GUI ו־tray משתמשים ב־runspaces.

**ראיה:** state סינתטי הוזז בפועל מתוך קריאת status. שני runspaces אמיתיים באינטרליבינג מבוקר הראו שפרופיל A נשאר Electron אך flags הדרושים לו הוסרו על ידי B. ביטחון גבוה בתופעות, בינוני בהתממשות בכשל יישום חי. כתיבה לא אטומית היא עובדה סטטית; לא שוחזר crash של writer.

**השפעה:** אובדן ראיית כשל בקריאת status, JSON שעלול להיקרע ותהליך ילד עם environment שגוי. **חסר:** interruption/migration/restart ותזמון UI אמיתי NOT RUN. **המלצה:** status טהור וכתיבה אטומית מינימלית כבר ב־receipt; child env מפורש בפונקציית ההפעלה; AppContext מלא רק אחר כך. אין לרפקטור את כל המנוע לפני הגנת הנתונים.

## F09: חוזי renderer

**עובדה:** [processAll:425-432](https://github.com/ElazarKrispel/desktop-rtl-patch/blob/02cc70a8b750de4bc88b740cf8a64f292a5c0325/src/desktop-rtl-patch.js#L425) קורא ל־leaf ללא S_PROSE; table:374 מדלג על table מסומנת; math:339-352 מחליף text nodes. נוסף: applyDir:288-296 אינו שומר dir מקורי; observer:500-527 אינו מעלה תא dirty לטבלת האב.

**ראיה:** payload המקור ללא שינוי ב־Chrome מבודד, חמישה כשלים שוחזרו ושתי בקרות עברו. אין browser errors. ביטחון גבוה מאוד ב־DOM הסינתטי; קריסת React/אפליקציית יעד עדיין לא ניתנת לאימות מתוך הראיות האלה.

**השפעה:** toggle שלא מכובד, סדר עמודות מיושן, כיוון מקורי שאובד ו־writer שמעדכן text node מנותק. **חסר:** framework rerender, selection/paste/undo/IME, clipboard וביצועים באפליקציות יעד NOT RUN. **המלצה:** gating ו־direction ownership, dirty tables ואישור מפורש לשכתוב raw math במשטחים מתאימים. math=false כבר קיים; קודם להשתמש בו/להגדיר preset. דף bidi-harness הישן אינו טוען payload נוכחי; לשמר דוגמאות ולהחליף את בסיס הבדיקה.

## F10: בדיקות ושחרור

**עובדה:** [Build:26-28](https://github.com/ElazarKrispel/desktop-rtl-patch/blob/02cc70a8b750de4bc88b740cf8a64f292a5c0325/scripts/Build-Release.ps1#L26) מדלג על קבצים חסרים; lib:2858 בוחר ZIP לפי סיומת, 2896 מקבל digest ללא קישור לשם, ו־[bootstrap:54-59](https://github.com/ElazarKrispel/desktop-rtl-patch/blob/02cc70a8b750de4bc88b740cf8a64f292a5c0325/install.ps1#L54) יורד לארכיון ללא אימות גם על כשל checksum request זמני. Herdr בוחר שם מדויק, אך גם בו parser אינו קושר שם. אין workflow בעץ, API Actions החזיר אפס.

**ראיה:** חמש בדיקות סינתטיות שחזרו פערים; פרטי expected/actual ב־packaging. נוספה בדיקת בתים ל־v2.5.0: checksum נכון, כל 38 הקבצים תואמים לתוכן commit, 27 עם שינויי סוף שורה בלבד ושמונה extras מול include policy. ביטחון גבוה בעובדות האלה. אין להסיק שלא בוצעו בעבר בדיקות מקומיות או שה־ZIP הקיים לא תקין.

**השפעה:** חבילה חסרה יכולה להיארז ולהתקדם בבדיקות צרות, asset לא נכון יכול להיבחר ופגיעה זמנית ב־checksum endpoint יכולה לבטל אימות. **חסר:** package install/upgrade ב־Windows נקי, signed update, adversarial extraction ו־crash recovery NOT RUN. **המלצה:** harness מבודד, manifest מחייב משותף, exact asset/checksum, fail-closed, CI ו־artifact שנבדק מאותו SHA. חתימות/provenance נפרדות מהוכחת checksum.

## N01-N04: תורי חקירה אחרי בדיקה

| מזהה | מה הוכח ומה לא | החלטה |
|---|---|---|
| N01 | ב־Remove-RtlCopyShellRegistrations:2546-2587, candidate command בבעלות מביא לבקשת מחיקה רקורסיבית של CLSID/verb האב. stub של Registry לכד בקשת מחיקה רקורסיבית של parent המכיל sibling זר. לא בוצעה מחיקה אמיתית או מחיקה במודל ולא הוכחה שכיחות מצב כזה | לקדם לממצא ממוקד על גרנולריות הבקשה, ביטחון גבוה; PR-04 מחייב תתי־מפתחות/values בבעלות, כשל discovery אינו הצלחה |
| N02 | update ASAR:2115-2124 בולע post-swap verify failure, כותב state, ובסבב Auto הבא אין verification. שוחזר עם swap מדומה וכשל verify מוזרק. לא נבדק archive פגום או restart של יישום | ממצא נוסף מאומת בזרימת הבקרה, PR-03 לפני בטא; אין הבטחת recovery עד שהעותק הפעיל מאומת |
| N03 | status:1887-1889 מחזיר Fresh/Repair לפני חשיפת block כאשר אין state תקין. שוחזר בשתי בדיקות; GUI פתוח לא הורץ | עובדת קדימות מאומתת, לא להחליף מצב אחד באחר; להציג existence/health/update בנפרד ב־PR-02/03 |
| N04 | מסלולי shutdown ו־force-stop נקראו; לא הורץ מגש עובד עם update/self-update/uninstall במקביל | עדיין לא ניתן לאימות, NOT RUN/BLOCKED בגבולות השלב. host מבודד עם events ייחודיים נדרש בשער PR-07 לפני בטא; PR-08 מרחיב את תיאום התהליכים לפי התוצאות |

אין להתייחס ל־N כאילו כבר הוכחו ב־PR #8. הטענות המצומצמות לעיל נשענות על הבדיקה החדשה בלבד.

## N05 חדש: פתיחת Herdr אינה משתמשת בחוזה הבידוד

Herdr profile ב־lib:552 מסתמך על CMD לסביבת XDG. [Start-RtlCopyApp:886-911](https://github.com/ElazarKrispel/desktop-rtl-patch/blob/02cc70a8b750de4bc88b740cf8a64f292a5c0325/scripts/lib/desktop-rtl-lib.ps1#L886) מפעיל exe ישירות ואין בו prebuilt branch. GUI:503, tray:244/583 ו־settings:225 קוראים לו. capture של Start-Process בבדיקה הראה XDG_CONFIG_HOME, XDG_STATE_HOME ו־HERDR_BIN_PATH חסרים והחזרת true; לעומת זאת ה־CMD שנוצר כולל אותם.

הבקשה השגויה מאומתת בביטחון גבוה. ההשפעה על פרופיל/session אמיתי מוסקת מהחוזה המתועד ונותרה NOT RUN; אין טענה שהושחת פרופיל. זהו חסם בידוד נתונים שמצדיק תיקון עם F03 ב־PR-01, ובדיקת recorder executable בטוחה לפני בדיקה חיה מאושרת.

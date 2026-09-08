# אימות עצמאי: lifecycle, נתונים ותוצאות

נבדק קוד מוצר ב־`02cc70a8b750de4bc88b740cf8a64f292a5c0325`. קראתי את כל ששת מסמכי סקירת המוכנות, את ארבעת קובצי הראיות ואת CLAUDE.md המקומי לפני גיבוש המסקנות. המסמך אינו משנה קוד מוצר ואינו אישור להפצה.

הפניות `lib`, `gui`, `tray`, `herdr` להלן הן בהתאמה `scripts/lib/desktop-rtl-lib.ps1`, `scripts/Install-DesktopRtlGui.ps1`, `scripts/DesktopRtlTray.ps1`, `scripts/lib/desktop-rtl-herdr.ps1`, כולן באותו commit. שורות נבדקו מול הקבצים בפועל; אין להעתיק אוטומטית מספרי שורות מהדוח המקורי.

## ראיות ושיטת בדיקה

[Test-LifecycleEvidence.ps1](Test-LifecycleEvidence.ps1) מחלץ הגדרות פונקציות מה־AST של קובץ המוצר המקורי, לאחר בדיקת SHA-256 של הקובץ. לא נטענה הספרייה בשלמותה. בדיקות המערכת הוחלפו בפונקציות גבול מדומות: watcher, בדיקת אפליקציה רצה, נעילת המנוע, לוג, Registry ופעולות agent. הכתיבה והמחיקה של F02/F03 מתבצעות באמת, אך רק תחת תיקיית fixture חדשה וייחודית בתוך תיקיית ראיות זו. אפילו הקיצור הוא קובץ טקסט פיקטיבי, לא קיצור shell. נעילת non-exe ב־F02 היא FileStream אמיתי ב־Windows שאינו משתף הרשאת מחיקה.

פקודת השחזור מתוך שורש ה־worktree:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File docs\reviews\2026-09-07-independent-validation\lifecycle\Test-LifecycleEvidence.ps1
```

הריצה האחרונה: Windows NT 10.0.26200.0, Windows PowerShell 5.1.26100.9168, ‏2026-09-07T16:56:42Z. ‏[results.json](results.json) מתעד מקור, סביבת ריצה, תוצאה ומגבלות לכל תרחיש. שישה assertions על התנהגות ה־baseline התקיימו והפקודה הסתיימה בקוד 0. משמעותם שהליקויים המתוארים שוחזרו בתנאי הבדיקה, לא שהמוצר עבר את תנאי הקבלה לתיקונם.

לא הופעלו/הופסקו אפליקציות עבודה, לא שונו התקנות מקור, לא נקרא או נמחק פרופיל משתמש אמיתי, לא נקראו/נכתבו מפתחות Registry אמיתיים, לא נוצרו קיצורי shell ולא נשלחו named events. לא הורץ GUI. לא הופעל מחזור התקנה/הסרה של מוצר אמיתי. תיקיות fixture נשמרו ומוחרגות ב־`.gitignore` המקומי. בקשת כלי משולבת לניקוי fixture והרחבת assertions נדחתה אוטומטית עם `blocked by policy`, ללא סיבה מפורטת; הניקוי לא נוסה שוב. ה־assertions נוספו בנפרד באמצעות עריכת קובץ בטוחה ונבדקו בריצה חדשה.

## F02: מאומת, ביטחון גבוה בגבול שנבדק

**עובדה בקוד:** `Invoke-CodexRtlUninstall` רושמת כשל מחיקת copy ב־`Certain/Leftovers` וממשיכה למחיקת shortcuts ולאחר מכן state/config: ‏lib:2942-2950, 2969-2970. ‏`Get-RtlInstalledApps` סופרת רק exe, ואף מתעלמת מ־state שנשאר ללא exe: ‏lib:2475-2485. לא נמצא receipt עמיד של הסרה חלקית.

**שחזור Windows מבודד:** לפני ההסרה האפליקציה הפיקטיבית נספרה; במהלך ההסרה נמחק `app.exe`, נשאר `z-locked.dat` נעול, ונמחקו state, config והקיצור הפיקטיבי. תוצאת ההסרה היתה `Certain=false`, שארית אחת; הספירה לאחר ההסרה היתה ריקה. זו אינה רק הסקה על סדר המחיקה אלא תוצאת filesystem אמיתית של Windows עם הפונקציה שחולצה, בתוך fixture.

**כל מסלולי הקריאה העיקריים:** GUI ‏415-423, ‏`Uninstall-DesktopRtl.ps1`:17-37, ו־tray:265-269 קוראים להסרה ומחשבים מחדש אפליקציות מותקנות. ה־GUI כבר זורק `[PARTIAL]` עם שאריות וה־CLI כבר מדפיס שאריות ויוצא בקוד 1. שניהם משמרים את הסוכן כש־`Certain=false`; אין צורך ליישם יכולות קיימות אלה מחדש. הבעיה: הסוכן שנשמר אינו מזהה את השארית כאפליקציה מנוהלת. `Invoke-Reconcile`, ‏tray:381-402, בונה menu/watchers מהספירה המצומצמת; menu של אפליקציות נבנה ב־tray:280-302. ‏gui:277-288 מסתיר הסרה כשגם המקור וגם exe חסרים; כאשר המקור עדיין קיים, state שנמחק מוביל ל־Fresh, ‏gui:316-319, וגם שם הסרה מוסתרת.

**השפעה:** שאריות תופסות מקום ונעלמות ממסלול הניהול הרגיל. direct CLI יכול עדיין לנסות שוב משום שהוא קושר פרופיל מראש, אך זה אינו self-service ברור למשתמש. הסקה נפרדת, לא שחזור: אם דווקא exe נשאר וה־state נמחק, הסוכן עשוי לספור את האפליקציה ולבנות אותה מחדש אחרי שהמשתמש ביקש להסיר. לכן הבעיה היא גם שימור כוונת ההסרה, לא רק קיום קובץ receipt.

**חסר:** NOT RUN: הפעלה מחדש של המגש/אשף, מקור שהוסר, Last-app עם agent אמיתי, Registry cleanup failure, תרחיש exe שנשאר וניסיון auto חוזר. הקריאה הסטטית מראה את מסלולי UI, אך אינה מחליפה הרצתם.

**המלצה:** רשומת הסרה אטומית קטנה (`CleanupPending`, artifacts ושאריות, בלי הרשאת מחיקה הנגזרת מנתיב שרירותי ב־JSON) לפני תחילת המחיקה. להפריד installed exe מ־managed installation; לשמור את הרשומה ואת דרך הכניסה לניקוי עד שהמחיקה והסרת רישומים מאומתות. הסוכן לא מתקין אוטומטית כאשר נשמרה כוונת הסרה. אין צורך להמתין למימוש AppContext מלא או GUI חדש כדי לעשות זאת.

## F03: מאומת, ביטחון גבוה

**עובדה בקוד:** Herdr שומרת נתונים פרטיים תחת StateDir/data ו־StateDir/state, ‏herdr:286-296. ‏`Sync-HerdrRtlConfig` שומר תוכן משתמש קיים, ומשתמש ב־seed מהמקור רק כשאין קובץ פרטי: ‏herdr:329-350. ה־launcher קובע XDG_CONFIG_HOME/XDG_STATE_HOME לנתיבים הפרטיים: ‏herdr:418-431. ‏lib:2960-2967 מוחקת את שתי התיקיות כברירת מחדל עבור `prebuilt`, בלי פרמטר מחיקת נתונים. ‏gui:388 מבטיח שנתוני התחברות/מטמון הם משותפים ויישמרו. ההודעה אינה נכונה ל־Herdr. הודעת tray:260 אינה מבטיחה שמירתם, אך גם אינה מגלה את מחיקת הפרופיל הפרטי.

**שחזור:** config מותאם, session פיקטיבי וסמן private state נמחקו כולם ב־`Invoke-CodexRtlUninstall` ללא switches. הוחזר `Certain=true`. אין טענה שנבדק session אמיתי של Herdr; זהו מבחן מיקום ומדיניות מחיקה של תיקיות שהמימוש מגדיר כפרטיות.

**השפעה:** אובדן התאמות משתמש ומידע של המופע הפרטי בעת הסרה רגילה. התקנה מחדש תקרא seed מהמקור במקום הקובץ הפרטי שנמחק; זהו מסלול סטטי של אובדן customization, לא בדיקת reinstall חיה.

**מסלולי עקיפה שחייבים להיכלל בתיקון:** כל שלושת callers להסרה מפעילים אותה ללא בחירת data policy. בנוסף `Uninstall-DesktopRtl.ps1`:43-46 מוחקת בסוף את StateDir כולו כאשר `-PurgeLogs` נבחר. תיקון שמשאיר data/state במנוע אך משאיר את מחיקת StateDir ב־CLI עדיין יאבד אותם. מחיקת לוגים אינה הסכמה למחיקת profile.

**חסר:** NOT RUN: Herdr אמיתי, uninstall/reinstall עם config/session אמיתיים, session/socket semantics בפורק, UI consent בפועל. די בהבדל הקוד/ההודעה ובמחיקת fixture כדי לאמת את הבעיה הנוכחית; אלה תנאי קבלה חיוניים לתיקון.

**המלצה:** ברירת מחדל שומרת private data, shared data ו־unknown data. בחבילת הביצוע הראשונה אפשר לא להוסיף purge פרופיל כלל, ורק לשמר נתונים ולהציג טקסט מדויק. אם המשתמש רוצה purge פרטי, להוסיף הסכמה נפרדת ומוגדרת לאחר מכן. לשמר `Sync-HerdrRtlConfig` שמעדכן רק bidi ולא מוחק customization. לא להחזיר purge של Codex משותף.

## F04: מאומת, עם צמצום והרחבה ממוקדים ביחס לדוח

**עובדה ושחזור:** lib:1900 מחזירה ללא אובייקט וללא exception כש־`Enter-RtlLock` מחזירה false. הקריאה שחולצה עם lock boundary מדומה החזירה 0 אובייקטים, ללא חריגה. **צמצום:** זו אינה החזקת lock אמיתי במנוע ולא הוצגה הודעת הצלחה בפועל ב־GUI.

**מסלולי צריכה:**

- GUI התקנה, ‏gui:370-374, קורא update ואז מתקין agent ומסמן Ok, בלי לבדוק שה־update בוצע. ה־preflight של האשף מפחית Deferred רגיל אך אינו מונע contention או פתיחת copy בין הבדיקה להחלה.
- CLI התקנה, ‏`Install-DesktopRtl.ps1`:36-39, בודק רק שקיים state אחרי הקריאה. fresh בלי state ייכשל; install חוזר עם state ישן עלול להדפיס הצלחה בלי ביצוע. אין לטעון שכל busy ב־CLI התקנה תמיד מדווח הצלחה.
- CLI עדכון, ‏`Update-DesktopRtl.ps1`:18-20, מדפיס `[OK]` אם state כלשהו קיים.
- Settings fallback, ‏`DesktopRtlSettings.ps1`:233-237, מדווח שנבנה מחדש אחרי חזרת update ללא exception.
- Tray pass, ‏tray:428-434, מסמן `ok=true` אחרי החזרה גם ב־Busy/Auto Blocked/Deferred. drain, ‏tray:504-520, מנקה LastErr ומשחזר tooltip מתוך status; אין כאן תמיד balloon הצלחה מפורש.
- Watch fallback, ‏lib:2191/2199, לוכד רק exceptions; אין תוצאת פעולה מובנית. ‏Herdr:546-577 חוזרת ללא תוצאה גם ב־AlreadyCurrent/Deferred.
- הסרה מהמגש, ‏tray:257-272, מפעילה PowerShell מוסתר ללא PassThru/Wait/redirection/result-file, מציגה רק התחלה, ואינה מוסרת exception או Leftovers. ה־GUI וה־CLI להסרה כבר מטפלים ב־Partial, כמפורט ב־F02.

**שני דיוקים שחייבים להיכנס לחוזה:** `Enter-RtlLock`, ‏lib:204-209, בולעת כל exception, כולל כשל הרשאה/פתיחת קובץ. אין להפוך אוטומטית כל false ל־Busy. כמו כן Deferred של Electron מגיע לאחר staging מאומת, ‏lib:2094-2099; Deferred של Herdr קודם לכל הורדה/בנייה, ‏herdr:568-577. הודעה אחידה "העדכון מוכן להחלה" תהיה שגויה ב־Herdr.

**השפעה:** המשתמש לא יודע אם הפעולה בוצעה, נדחתה או לא התחילה; מהגדרות עלולה להופיע הבטחה שלא חלה. הסרה מוסתרת יכולה להיכשל בלי דרך ברורה לדעת מה קרה.

**חסר:** NOT RUN: contention אמיתי של engine lock, GUI rendering, כשל worker מוסתר/סגירת UI והמשכיות תוצאת סיום, בדיקות exit codes מחבילת מוצר. רמת הביטחון גבוהה בזרימת הקוד ובשחזור helper, בינונית בהצגת ה־UI בפועל.

**המלצה:** Result v1 קטן לפני החלפת stack: `Succeeded`, `AlreadyCurrent`, `Busy`, `Deferred`, `Blocked`, `Partial`, `Failed`, עם operationId/appId/errorCode ו־`prepared` ל־Deferred. Result של update נפרד מתוצאת התקנת agent כדי שכשל agent אחרי copy תקין לא יוצג כאילו copy כלל לא הותקן. receipt/result אטומי מאפשר לדווח גם לאחר restart; completion של process הוא אות לקריאת התוצאה, לא הוכחת הצלחה. למפות לכל ה־callers באותו PR. לא להחביא את הבעיה רק על ידי שינוי הטקסט ב־GUI.

## N01: כיוון החקירה אומת באופן מצומצם

lib:2568 מעלה LocalServer32 ל־CLSID אב, ‏2577-2582 מאמתת שה־command מצביע לעותק, ואז 2583 מבקשת `Remove-Item -Recurse` על האב כולו. אין בדיקה שהאב ריק; זו סתירה להערה ב־2544-2545. ה־fixture in-memory נתן CLSID עם LocalServer32 בבעלות העותק ו־ForeignSibling/ערך אב שאינם בבעלות; הפונקציה ביקשה למחוק את האב ברקורסיה והחזירה 0 Leftovers. הראיה מוכיחה delete scope שנבקש, לא קיום רישום זר כזה במחשב או התנהגות provider אמיתי.

ה־Icon fallback ב־2581 פועל רק כשלא נמצא verifyExe מ־command. Command חיצוני ברור אינו נדרס על ידי Icon פנימי, נקודת הגנה שצריך לשמר. כאשר אין command ברור, Icon מוכיח מיקום אייקון בלבד ואינו receipt לבעלות על כל verb. בנוסף discovery errors ב־2561 וקריאת verify ב־2578 נבלעים ולא נכנסים ל־Leftovers. אלה תתי־סיכונים סטטיים; לא הופעלו failure fixtures נפרדים ולא נטען ששוחזרו. unquoted command עם רווחים נחתך ב־`Get-RtlCommandExePath` (2528-2535), בדרך כלל שמרני כשאינו תחת CopyRoot; exact behavior דורש מטריצה.

**המלצה:** לכלול תיקון היקף המחיקה בחבילת בטיחות ההסרה: להסיר owned leaf/values בלבד, להסיר אב רק כשהוא ריק ובעלות מוכחת, ולתת תוצאה Unknown/Partial לכשל discovery/read. לא להשתמש ב־Icon לבדו כאישור למחיקת subtree. NOT RUN: Registry מבודד אמיתי, foreign sibling/value preservation, discovery/ACL failure, environment-variable/unquoted parsing matrix. השאלה לא הופכת אוטומטית ל־F11 גורף; קיימת כאן ראיה חדשה לתתי־טענה מוגדרת.

## N02: פער התאוששות מאומת בתרחיש failure injection

lib:2115-2123 לוכדת כל כשל live verification ב־ASAR וממשיכה, בעוד dir/inline זורקות. ב־2124 נכתב state, ב־2125 marker הגדרות, ב־2126 מתאפסת חסימה וב־2128 מסומן done. בסיבוב הבא `AlreadyCurrent`, ‏lib:1963-1980, לא מאמת payload/ASAR. ה־config sync אינו תחליף: ‏lib:1238/1256 מחזירה בלי פעולה כשהקובץ חסר או hash ההגדרות תואם.

**שחזור:** פונקציית update המלאה שחולצה קיבלה warm staging פיקטיבי שאומת; גבול atomic swap היה no-op מבוקר; verify על live הוגדרה לזרוק `[VERIFY]`. בסוף נכתב state עם payload hash ריק והתקבל done. בסיבוב Auto נוסף נרשמו 0 קריאות verification. הזרקת הכשל אינה מוכיחה שה־swap עצמו משחית קבצים; היא מפריכה את ההערה שה־poll הבא תמיד יבדוק מחדש אחרי כשל live verify.

**השפעה:** copy שלא אושר עלול לקבל מצב עדכני וללא repair אוטומטי. כשל read-lock זמני אינו הצדקה לסמן healthy; אפשר לשמר installation מוצלח ובריאות PendingVerification בלי לבצע rebuild מיידי.

**המלצה:** לא לפרסם Healthy/clear-block לפני verification מתאים. Persist `PendingVerification`; retry verification מוגבל אחרי restart; לקבוע כשל מבני מול זמני. dir/inline/prebuilt צריכים אותו חוזה תוצאה, גם אם מדיניות rollback שונה. rollback אחרי launch/profile changes דורש מדיניות נפרדת ואין להבטיח rollback מושלם מראש. NOT RUN: swap אמיתי, קובץ ASAR אמיתי, restart process, נעילה זמנית אמיתית. יש לכלול את הפער המאומת בחבילת result/recovery הראשונה, לא לדחותו ל־GUI.

## N03: הסתרת חסימה מאומתת; החלפת סדר מוחלטת אינה מסקנה הכרחית

lib:1880 קוראת block, אך 1887-1888 בוחרות Fresh/Repair לפני Blocked. רק בענף 1889 מוזן `BlockedError`. בדיקת source קיים + block תקף + state/exe חסרים החזירה `Fresh` ו־`BlockedError=null`. ‏gui:316-319 תציג "מוכן להתקנה"; ‏tray:557-575 מודיעה על חסימה רק כאשר State שווה Blocked, ובלא exe האפליקציה ממילא לא נספרת. זהו פער visibility שנראה בקוד ושוחזר ב־status, לא באשף חי.

**המלצה:** לשמר קדימות SourceMissing כשאין מקור; לא להחליף בפשטות את כל המצבים ל־Blocked. להוסיף ממד UpdateStatus/BlockedError שאינו תלוי ב־InstallationState. Fresh יכול להיות נכון מבחינת התקנה ובמקביל להיות AutoBlocked. יש להציג סיבת כשל וניסיון ידני מפורש. NOT RUN: UI live failed-first-install/restart. עדיפות לאחר data/results, אפשר יחד עם מינימום state contract.

## N04: עדיין לא ניתן לאימות ברמת lifecycle של תהליכים

עובדות סטטיות: drain ב־tray:473 מטפל ב־quit לפני בדיקת completion. ‏`Invoke-TrayQuit`, ‏585-594, משחררת timers/watchers/icon/event/mutex ויוצאת בלי להמתין ל־PassPs/PassRs או להגדיר cancellation בטוח. ‏`Stop-RtlOwnedProcesses`, ‏lib:2616-2645, מסמנת event ומבצעת force-stop אחרי grace period. ‏Restart-RtlAgentTray ו־Install-RtlAgent מגיעות אליה ב־2816 וב־2793; ‏Invoke-RtlAgentLastCleanup מגיעה דרך Unregister-RtlAgent, ‏2823-2829/2772-2778. פעולה מאפליקציה אחרת יכולה להגיע ל־restart בזמן pass.

עם זאת, מנגנוני התאוששות קיימים: building sentinel ב־lib:1988-2043 ו־CopyRoot/OldRoot self-heal ב־1907-1911. אין להסיק מהיעדר המתנה ב־Quit ששוחזרה השחתה או שההתאוששות אינה עובדת. גם הטענה שה־event תמיד מתאפס אחרי Dispose דורשת בדיקת handles אמיתית בכל הצדדים; לא נבדקה כאן.

**NOT RUN / BLOCKED בשלב הנוכחי:** worker אמיתי עם quit/restart/force-stop; named event ו־mutex ברמת processes; kill בזמן mirror, swap ו־agent update. יש לבנות host בדיקה עם roots ושמות IPC ייחודיים, checkpoints נשלטים ותהליך פיקטיבי בלבד, ולבדוק recovery אחרי סיום/קריסה. שום אירוע אינו רשאי להשתמש בשם resident agent האמיתי. עדיפות: תכנון הבדיקה כחלק מ־recovery, בלי לתקן race מומצא או להכניס שכתוב לא מתוחם.

## PRים מוצעים לתחום זה

| PR | Scope ורכיבים | תלויות | תנאי קבלה ובדיקות | דרך נסיגה |
|---|---|---|---|---|
| שמירת נתוני Herdr והסכמה מדויקת | lib uninstall, herdr config/launcher contract, GUI/tray messages, uninstall CLI PurgeLogs, README data policy | ראשון; בלי AppContext חדש | default uninstall/reinstall משמר config/session; PurgeLogs מוחק רק לוגים; shared/unknown נשמרים; fixtures לפני/אחרי, אחריהם VM מאושר | להחזיר UI בלבד אם צריך; לא לחזור אוטומטית להתנהגות מוחקת נתונים ולא למחוק data retained בהורדת גרסה |
| תוצאת פעולה v1 וכל הצרכנים | lib update/locks, herdr update, install/update CLI, GUI, Settings, tray worker + result receipt | schema מינימלי מוסכם; כתיבה אטומית לרשומת תוצאה | Busy אמיתי מול AccessDenied, Deferred prepared/unprepared, stale state, Partial/worker exception/crash נראים; אין הצלחה מהיעדר exception | תוספת additive עם human CLI תואם; ישן יכול להתעלם משדות חדשים, schema חדש שאינו נתמך לא מפעיל פעולה הרסנית |
| הסרה מתחדשת והיקף בעלות | uninstall, installed enumeration, GUI/tray reconcile, agent cleanup, Registry ownership (N01) | תוצאת פעולה v1 ורשומה אטומית; מדיניות data | non-exe נעול, exe נמחק, state+cleanup intent נשמרים; restart/source missing/last app; ניקוי חוזר idempotent; foreign Registry sibling נשמר; Auto אינו מתקין מחדש | receipt ותיקיות נשמרים; fallback CLI מובנה; אין rollback למחיקת receipt לאחר partial |
| אימות live והצגת בריאות נפרדת | lib post-swap/current/status, adapter verify contract, GUI/tray presentation | תוצאת פעולה v1; מינימום state schema | injected temporary/structural verify errors אינם Healthy; restart+poll מאמתים; bounded retry; Fresh/Repair אינם מסתירים Blocked; old copy פעיל מוצג בנפרד מעדכון חסום | שמירת copy תקין ורשומת Pending; חזרה לגרסת מנוע קודמת רק אם מבינה schema, בלי לטעון לבריאות שלא אומתה |
| recovery process matrix | בדיקות עם host/roots/IPC ייחודיים; תיקון ממוקד רק אם N04 משוחזר | חוזי פעולה והסרה זמינים | worker ב־mirror/swap, quit/restart/selfupdate/other-app uninstall, event handles, abandoned lock, תוצאת פעולה נשארת נגישה | PR בדיקות ניתן לביטול בנפרד; תיקון תהליך נשען על checkpoint/receipt ויכולת חזרה ברורה |

המלצה לביצוע ראשון בתחום זה: להתחיל בשמירת נתונים ומינימום תוצאות/רשומה עמידה, ולהשלים באותה חבילת אישור את discoverability וה־verification gap שאומתו. גבולות כתיבה ו־encoding נבדקים במסלולי האימות האחרים ומצטרפים בהתאם לעדיפות הכוללת. לא להתחיל במנהל WPF/Tauri, לא לשנות כל globals, לא להוסיף purge profiles ולא לתרגם את המנוע כולו. לבקש הכרעת בעלים על מדיניות שמירת נתונים ותמיכת adapters; המלצה: preserve כברירת מחדל והוצאה זמנית של Herdr מהפצה חדשה עד לתיקון ואימות, אם חבילת השימור לא נכנסת מייד.

# ארכיטקטורה והחלטות לבעל הפרויקט

## ההמלצה שלי

לשמר כעת את מנוע PowerShell, התאמות האפליקציות ו־JavaScript של ה־renderer; להקשיח את חוזי הנתונים והתוצאות; לבנות בהמשך מנהל Windows ב־C#/.NET 10/WPF שמפעיל worker בתהליך נפרד. ההמלצה על WPF מתאימה למוצר הנוכחי, אך אינה הצדקה לתרגם את כל המנוע או להקדים עיצוב לתיקוני אמינות.

הסיבה העיקרית היא אופי המוצר. רוב הסיכון והתחזוקה נמצאים ב־Windows paths, Registry, קיצורים, תהליכים, profile ownership ו־recovery. קוד PowerShell כבר משתמש ב־.NET/WinForms ו־Win32. מעבר מדורג ל־C# משאיר אפשרות לאותו ממשק worker ולספריות Windows קרובות, בלי לחייב גם Rust וגם ממשק web וגם bridge ל־PowerShell. אין בידינו נתון על מומחיות Maintainer ב־C#/Rust/TypeScript; יתרון צוות מוכח ב־Tauri יכול לשנות את ההכרעה.

WPF היא מסגרת Windows עם XAML, binding, layout, styles/templates, ויש לה FlowDirection וכיווניות מקומית לאזורי טקסט. זה בסיס מתאים ל־RTL, לא הוכחה שכל control או עיצוב שייבחר יפעל נכון. [WPF overview](https://learn.microsoft.com/en-us/dotnet/desktop/wpf/overview/), [bidirectional features](https://learn.microsoft.com/en-us/dotnet/desktop/wpf/advanced/bidirectional-features-in-wpf-overview).

.NET 10 היא LTS פעילה עד 14 בנובמבר 2028 לפי תיעוד שנבדק היום. להפצה self-contained יש יתרון אפשרי של היעדר דרישת runtime נפרד, אך האחריות לעדכון runtime נשארת אצל המוצר. אין לבחור מודל הפצה בלי לכלול זאת בתחזוקה. [מדיניות תמיכה של .NET](https://dotnet.microsoft.com/en-us/platform/support/policy/dotnet-core).

## החלופות

| חלופה | התאמה למוצר | המחיר שצריך לקבל | המלצה |
|---|---|---|---|
| WinForms/PowerShell הקיימים | מאפשרים תיקוני אמינות ובטא בלי לשנות installation engine | תלות בסקריפטים, VBS ותיאום runspaces; חוויית setup טכנית | לשמר לשלב ההקשחה; אין צורך לייפות לפני data/recovery |
| C#/.NET/WPF | Windows מקומי, UI עצמאי, קוד integration קרוב למערכת הקיימת | XAML ותחזוקת packaging/signing/runtime; tray ו־IPC עדיין דורשים מימוש ובדיקות | ברירת מחדל לתרחיש אנכי יחיד אחרי contracts |
| Tauri 2/Rust עם UI web | בחירה טובה אם הצוות חזק ב־Rust/web או יש יעד ממשי לפלטפורמות נוספות | core Rust, WebView ו־IPC בנוסף למנוע הישן בתקופת מעבר; adapters נשארים Windows-specific | חלופה תקפה, אינה הוכחת יתרון אמינות או ביצועים |
| Electron | UI web אפשרי, אך לא זוהה כאן צורך מוצרי שמחייב runtime Chromium משלו | משטח תחזוקה נוסף שאינו פותר state/path/registry | אין סיבה לבחור בו כברירת מחדל כרגע |

Tauri משתמשת ב־core process ב־Rust וב־WebView של המערכת, ב־Windows WebView2. המנגנון שלה לעדכון דורש חתימות; זה נכס, אבל הוא מגן על עדכון חבילת המנהל ולא פותר אוטומטית הורדת Herdr, fuse edits או uninstall ownership. [Process model](https://v2.tauri.app/concept/process-model/), [Updater](https://v2.tauri.app/plugin/updater/).

לא נערכו benchmarks. שום framework אינו חוסך בעצמו את העתקת אפליקציות המקור או staging. מתחילים במדידת שלושה דברים בנפרד: מנהל במנוחה/פעולה, copy+patch, והשפעת renderer. לא לבחור stack על הבטחה מספרית שאינה נמדדה.

הבדיקה התיעודית השתמשה ב־Context7 CLI: library WPF -> /dotnet/wpf -> docs, ובשאלה נפרדת library Tauri -> /tauri-apps/tauri-docs -> docs. פלט WPF היה בחלקו כללי ולא ענה ישירות על RTL, ולכן הושלם מול מסמכי Microsoft הרשמיים. ההכרעה אינה מסתמכת על ציון הדירוג של Context7, שהוא ציון מאגר תיעוד ולא benchmark למוצר.

## מה לשמר, מה לתקן ומה לשנות בהדרגה

| רכיב קיים | החלטה | היקף השינוי |
|---|---|---|
| שישה profiles/ארבעה renderer modes | לשמר | provenance ו־compatibility per adapter; לא קטלוג חדש בשם אחר |
| staging חם והחלפת copy | לשמר ולתקן | verification סופי לפני commit של health, rollback והתאוששות שנבדקו |
| bin.old + generation readiness של agent | לשמר | לסגור N04 בבדיקה ייעודית ולהרחיב manifest runtime |
| blocked.json מקושר לחתימת מקור וגרסת כלי | לשמר | classification/backoff; לא לבטל retry guard; אין כאן חתימה קריפטוגרפית |
| payload, mutation batching ו־code isolation | לשמר | חוזי toggles/dir/table/math, בלי היפוך טקסט |
| הגדרות קיימות כולל math=false | לשמר | לבדוק שהן מכובדות, preview בעת GUI חדש |
| אבחון מסונן | לשמר | regression ל־redaction, preview והסכמה לפני שיתוף; אין איסוף שיחות חדש |
| process-wide env ו־script globals | לשנות בהדרגה | child env ו־AppContext מפורשים; shim זמני במקום rename גורף |
| state/operation lifecycle | שינוי מבני מוצדק | receipt גרסאי, atomic write, status טהור ותוצאות terminal עמידות |
| WinForms/VBS | החלפה מוצדקת בהמשך | manager/launcher עצמאיים מול חוזה מנוע מוכח |

## החוזה המוצע

שלושה ממדים למצב: קיום התקנה מנוהלת, בריאות העותק ומצב העדכון. retained data לאחר הסרה אינו שקול להתקנה. CleanupPending עוצר autopatch. Blocked של build חדש אינו מסתיר עותק תקין ישן, אבל צריך להציג שהוא מפגר ולא לשקר שהוא עדכני.

receipt מינימלי נכתב אטומית לפני פעולה הרסנית ושומר operationId/intent/phase/leftovers. paths נגזרים מ־appId ומדיניות קבועה, לא מאמון עיוור ב־receipt. schema migration נעשית תחת lock עם backup. journal אינו מבטיח rollback של פרופיל משותף שהיישום המקורי שינה.

UI שולח בקשה מוגדרת עם appId ואופציות מורשות; worker מחזיר אירועים ותוצאה. אין eval, shell command חופשי או החלטת מחיקה ב־UI. לכל child process יש path, argv, cwd, env ו־launch mode משלו. ה־adapter מספק הבדלים אלה; מנגנוני ownership/locking/results/recovery משותפים. אין חובה ליצור שמונה interfaces לכל adapter לפני שיש צורך מוכח בהם.

## הכרעות שנדרשות מאלעזר

| החלטה | המלצה | מתי צריך להכריע |
|---|---|---|
| אישור חבילת המימוש הראשונה | PR-00..03 בלבד, כפי שהוגדרו בתכנית | עכשיו, לפני שינוי מוצר |
| מדיניות מידע פרטי | uninstall שומר נתונים; PurgeLogs רק לוגים; אין purge חדש בחבילה הראשונה | לפני PR-01 |
| היקף הבטחת copy-only | למנוע בריחה דרך links קיימים בכל כתיבה; להגדיר במפורש היקף הגנה מהחלפה מקבילה באותו משתמש. יעד שאי אפשר לאמת נחסם | לפני PR-04; לא לטעון לעמידות TOCTOU בלי בדיקה |
| גרסאות/אפליקציות לבטא | מועמדים ראשונים Codex ו־OpenCode אחרי אימות גרסאות ספציפיות; להוסיף Traycer רק עם ראיות חיות. Herdr במסלול נפרד אחרי F03/N05, T3/Grok רק למטריצה שנבדקה | לפני שער בטא; זו הצעת בחירה, לא הצהרת תאימות נוכחית |
| Windows וארכיטקטורה | Windows 11 x64 כיעד בדיקה ראשון; Windows 10 ו־ARM64 רק לאחר הגדרת גרסאות נתמכות ובדיקה ייעודית | לפני התחייבות support ציבורית |
| raw math עד שיש בדיקות framework | להשאיר יכולת קיימת, להציע preset שמכבה rewriting למשתמשי בטא כשאין ראיות תאימות; לא לבנות safe mode שני | לפני PR-09 ופרסום defaults |
| סטאק המנהל ומודל תחזוקה | WPF/.NET 10 עם worker נפרד; לתעד אם ניסיון Maintainer ב־Rust/web משנה את ההמלצה. self-contained אפשרי רק עם מחויבות לעדכון runtime | לפני PR-10, לא חוסם הקשחה |
| סביבת בדיקות חיות | VM/חשבון בדיקה עם נתונים סינתטיים; פעולות במחשב העבודה רק באישור נקודתי | לפני E2E, לא נדרש לקריאת קוד |
| זהות מפרסם, חתימות וערוץ הפצה | artifact מאומת מאותו SHA; חתימת update/code, ניהול מפתחות ו־beta מוגדרת לפני קידום לקהל לא טכני | לפני פרסום, ללא יצירת מפתחות או שינוי הגדרות בשלב הנוכחי |
| מדד הצלחת בטא | install/use/update/uninstall/reinstall ללא עזרה, failure recovery גלוי, דיווח מדגם ובקשות תמיכה; לקבוע יעד מראש ולא להסתפק ב־downloads | לפני הזמנת המשתמשים |

אין צורך להכריע כעת על marketplace, לקוח AI חדש, מערכות נוספות או שכתוב מלא. ההחלטה הקרובה היא אם לאשר חבילת שמירת מידע והתאוששות, עם בדיקות הקבלה המפורטות.

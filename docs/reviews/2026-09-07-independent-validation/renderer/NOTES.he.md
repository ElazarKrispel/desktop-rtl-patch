# אימות עצמאי של F09 ושל כיסוי ה־renderer

נבדק הקוד ב־`02cc70a8b750de4bc88b740cf8a64f292a5c0325`. נקראו כל ששת מסמכי הסקירה וכל ארבעת קובצי הראיות, וכן `CLAUDE.md` המקומי. אין שינוי בקוד מוצר. ההשוואה לענפים ול־HEAD העדכני מנוהלת בפנקס הראשי.

## מסקנה וסוג הראיה

F09 מאומת ברמת קוד והרצת payload אמיתי על DOM סינתטי בדפדפן Windows. הטענות על toggle וטבלה שוחזרו. החלפת text node במתמטיקה ושבירת עדכון שמחזיק הפניה לאותו node שוחזרו; קריסת React או אפליקציית יעד **לא נבדקה ולא הוכחה**. אין הצדקה לשכתוב מנוע BiDi. יש הצדקה לתיקונים קטנים עם חוזי בעלות ובדיקות רגרסיה.

הפקודה מהריפו:

```powershell
node docs/reviews/2026-09-07-independent-validation/renderer/probe-renderer.mjs
```

תוצאה סופית: exit 0, חמישה תרחישי כשל שוחזרו ושתי בקרות עברו, ללא שגיאות JavaScript בדפדפן. `REPRODUCED` מציין שחזור של התנהגות לא רצויה, ואינו PASS של המוצר. הראיה המלאה, expected/actual וסביבת ההרצה נמצאים ב־[renderer-results.json](renderer-results.json). הבדיקה קוראת את `src/desktop-rtl-patch.js` בזמן הרצה ומבצעת אותו ללא שינוי. SHA256: `8fc59dc6488b66399f02f89bebe1232c3e2e6c783fccbcfa23e593b2d74124c0`.

סביבה: Node v24.14.0, Windows, Chrome 152.0.7977.76 במצב headless, פרופיל חדש ותהליך חדש של הבדיקה, מסמכי about:blank בלבד. MutationObserver ו־requestAnimationFrame מקוריים, ללא mocks. לא הופסקו תהליכי עבודה ולא נפתחו אפליקציות יעד. אין Registry, קיצורים, named events, פרופילים קיימים, clipboard או התקנה חיה. הבדיקה מסיימת רק את הדפדפן שהיא עצמה פתחה.

## פנקס תתי־טענות

| מזהה | עובדה והפניה בקוד | סיווג וביטחון | השפעה אפשרית | המלצה וחסר לאימות מלא |
|---|---|---|---|---|
| F09.a | `processAll` מפעילה `processLeafContainers` בלי `S_PROSE`, בשורות 425-432; leaf selectors בשורה 67 ומימוש בשורות 402-410 | מאומת, גבוה, קוד + Chrome סינתטי | prose=false משאיר פסקה ללא dir אבל div/span/label בעברית מקבלים RTL | להתנות את leaf processing בחוזה המשטחים. לבדוק nested spans בתוך פסקה וטבלה, כפתורים וקישורים, ולתעד אם יש משטח UI נפרד. לאמת באפליקציות היעד לפני שינוי selectors |
| F09.b | `processTableColumns` מחזירה מייד כשקיים TABLE_FLAG, שורה 374, ואין ענף שמסיר direction כשהחלטת הטבלה משתנה, שורות 388-391 | מאומת, גבוה, קוד + Chrome סינתטי | טבלה ממוחזרת מעברית לאנגלית נשארת RTL, אף שהתאים כבר איבדו RTL; גם סריקה חוזרת של הטבלה לא מתקנת | לחשב כיוון מחדש ולשחזר dir קודם עם בעלות. קבלה: עברית לאנגלית וחזרה באותה טבלה ובכל נתיבי mutation |
| F09.c | `isolateMath` יוצרת span/fragment ומחליפה text node בשורות 339-352 | מאומת לגבי שינוי DOM וניתוק node, גבוה; עדיין לא ניתן לאימות לגבי React/אפליקציית יעד | writer שמחזיק reference ל־text node המקורי מעדכן node מנותק, ולכן הטקסט הגלוי נשאר ישן | אין לתאר replaceChild כבטוח ל־framework רק מפני שאין innerHTML. לשמר CSS עבור math מרונדר ולבחון rewriting של raw math רק במשטח שיש לו חוזה מתאים. לבדוק rerender עם framework ו־streaming אמיתי; לא לטעון לקריסה |
| F09.d, חידוד עצמאי | `applyDir` משמרת רק MARK ולא ערך dir קודם; שורות 288-296 | מאומת, גבוה, קוד + Chrome סינתטי | p עם dir=ltr נהפך ל־rtl ואז מאבד לגמרי את dir לאחר תוכן אנגלי; תלות בירושת parent עלולה לשנות תצוגה | לשמור initial dir ומצב absent בנפרד, ולהגדיר מה עושים כשיישום משנה dir בזמן שה־patch פעיל. לבדוק גם dir=auto ו־rtl מקוריים |
| F09.e, חידוד עצמאי | `CTX_SEL` בשורה 68 עוצר ב־td/th; `contextOf` בשורות 500-504 ו־observer בשורות 520-527 אינם מעלים dirty cell לטבלת האב | מאומת, גבוה, קוד + Chrome סינתטי | טבלה אנגלית שהתאים שלה הופכים לעברית מקבלת RTL בתאים בלבד; RTL של סדר העמודות מתעדכן רק אחרי אירוע שמספק את הטבלה עצמה כשורש | לתזמן בנפרד dirty tables בסריקה המוגבלת הקיימת. הסרת ה־early return בלבד אינה סוגרת את תרחיש streaming |

שורות כל ההפניות הן ב־`src/desktop-rtl-patch.js` ב־commit המצוין. קישורים יציבים: [processAll](https://github.com/ElazarKrispel/desktop-rtl-patch/blob/02cc70a8b750de4bc88b740cf8a64f292a5c0325/src/desktop-rtl-patch.js#L425), [table](https://github.com/ElazarKrispel/desktop-rtl-patch/blob/02cc70a8b750de4bc88b740cf8a64f292a5c0325/src/desktop-rtl-patch.js#L372), [math](https://github.com/ElazarKrispel/desktop-rtl-patch/blob/02cc70a8b750de4bc88b740cf8a64f292a5c0325/src/desktop-rtl-patch.js#L315), [ownership](https://github.com/ElazarKrispel/desktop-rtl-patch/blob/02cc70a8b750de4bc88b740cf8a64f292a5c0325/src/desktop-rtl-patch.js#L288), [observer](https://github.com/ElazarKrispel/desktop-rtl-patch/blob/02cc70a8b750de4bc88b740cf8a64f292a5c0325/src/desktop-rtl-patch.js#L500).

## מיפוי מסלולים ומה ראוי לשמר

- config נקראת פעם אחת בשורות 38-47. `enabled=false` מחזיר לפני init; הבקרה הראתה ללא style, ללא direction וללא החלפת node. אין כאן API לשינוי config בזמן ריצה, ואין לדרוש live toggle בלי החלטת מוצר.
- bootstrap מפעיל style ו־processAll פעם אחת, שורות 486-488. סדר הפעולות: math, prose/list, cells/table, leaf, input. אירוע input, שורות 490-494, מגיע למסלול input בלבד. observer מאגד context roots ב־Set ומעבד אותם ב־rAF, שורות 497-537. אין בסיס לטענה שכל הקשה גוררת תמיד סריקה של כל הדף.
- prose: TEXT_SEL בשורות 64-65 ו־processText בשורות 356-360; רשימות בשורות 395-399. תאים מופרדים ל־S_TABLES בשורות 363-367. שני המסלולים מדלגים על input ו־code ומקבלים `rtl` או null דרך מדיניות detection בשורות 299-307.
- קוד: CODE_SEL בשורות 62-63, סינון subtree ב־textWithoutCode בשורות 121-133, guards ב־processText/leaf/input, בידוד CSS בשורות 462-466. תוצאת הבקרה: תוכן code נשמר וכיוון מחושב נשאר ltr. אין היפוך מחרוזות.
- inputs: INPUT_SEL בשורות 54-55, processInputs בשורות 413-422. מדלג על code ועל Lexical, נוגע ב־dir וב־styles בלבד; בידוד math מדלג מראש על editable בשורה 329. כיוון input בבקרה התעדכן מעברית לאנגלית. בדיקת input event אינה בדיקת IME/selection/undo.
- math: guards בשורות 319-329 מונעים wrapping חוזר באיים, בקוד ובקלט. הבדיקה מאשרת שמחרוזת textContent נשמרת בתחילת הבידוד, אך זהות node אינה נשמרת. זה ההבדל בין שימור תוכן לבין תאימות ל־renderer מנוהל.
- האפשרות להשבית math **כבר קיימת**: checkbox ב־`scripts/DesktopRtlSettings.ps1:136`, שמירה בשורה 196, ברירת מחדל ב־`scripts/lib/desktop-rtl-lib.ps1:695`, וההתניה ב־payload:428. לכן אין לבנות מנגנון safe mode שני; תחילה להשתמש בחוזה הקיים. בעתיד אפשר להוסיף preset מובן או להפריד raw-math rewriting מ־CSS למתמטיקה מרונדרת. שינוי ברירת מחדל דורש החלטה על רגרסיית תצוגת raw math.

## מצב הבדיקות הקיימות

`test/bidi-harness.html` הוא דף השוואה היסטורי שימושי, לא regression suite של payload הנוכחי. הוא מכנה את המצב החדש v0.2.0 בשורות 47 ו־93, מכיל CSS מועתק בשורות 36-40 ופונקציות detection/applyMode מקומיות בשורות 72-92. אין script src שטוען את `src/desktop-rtl-patch.js`, אין observer, אין config ואין בדיקות טבלאות או math. ה־payload הנוכחי מזדהה 1.3.1 בשורה 34. יש לשמר את דוגמאות הטקסט ולחבר בדיקות חדשות לקובץ המקור האמיתי, ולא להציג את הדף הישן כאילו הוא בודק אותו.

`test/renderer-injection.harness.ps1:64-67` מייצר payload סינתטי `window.__payloadSentinel = 1`; האימותים בשורות 71-103 בודקים מיקום ותגיות הזרקה, לא התנהגות RTL. אלו בדיקות מועילות בשכבה אחרת. לא הרצנו את הסוויטה הזאת במסגרת מסלול renderer, משום שהיא כוללת גם lifecycle שאינו בתחום בעלות בדיקה זו; אין לייחס לה PASS מהבדיקות החדשות.

## PR מוצע לאחר חבילת אמינות המנוע

**Scope:** תיקוני toggle, שינויי direction שניתנים לשחזור, סריקת טבלאות שהתוכן שלהן השתנה, והפרדת math DOM rewriting מחוזה direction. קבצים: payload, fixtures browser חדשים, שילוב בפקודת הבדיקות וב־CI, וטקסט עזרה להגדרות במידת הצורך. ללא GUI חדש, ללא reimplementation של Unicode, ללא שינוי מקביל במנוע התקנות.

**תנאי קבלה:** חמשת התרחישים כאן הופכים לבדיקות regression של ההתנהגות הרצויה; הבקרות נשמרות. כל toggle נבדק גם בתוך nested elements. טבלה חוזרת לכיוון המקורי אחרי החלפת שפה, ובשינוי characterData אין צורך להוסיף DOM מלא. שיקום direction מכסה absent/ltr/rtl/auto ושינוי מצד האפליקציה. קוד ו־logical text נשמרים. טיפול raw math נבדק עם writer השומר node, framework rerender, clipboard, selection, undo ו־streaming. כל גרסת אפליקציה במטריצת הבטא צריכה בדיקה חיה נפרדת בסביבה שהמשתמש אישר.

**נסיגה:** rollback לגרסת payload הקודמת דרך תהליך העדכון הקיים לאחר שנבדק; לא לבצע שכתוב schema חד־כיווני במסגרת PR זה. אפשר להשבית math דרך ההגדרה הקיימת ולהפעיל מחדש את העותק במסלול ההגדרות, אך אין לטעון שזה מחזיר DOM שכבר הוחלף בתוך חלון קיים.

**NOT RUN:** אפליקציות יעד, React runtime, paste/undo/selection/IME, screenshot של אפליקציה אמיתית, performance baseline. אלו אינם תנאי PASS שהושלמו.

ניקוי תיקיות הפרופיל הסינתטיות שנוצרו לבדיקה נדחה על ידי מנגנון האישור האוטומטי עם `blocked by policy`, ללא פירוט נוסף. לא ניסינו לעקוף את הדחייה. התיקיות נותרו בתוך תיקיית הבדיקה בלבד ומוחרגות ב־`.gitignore`; הן אינן חלק מהראיות למסירה.

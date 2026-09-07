# פנקס אימות: F01–F10

**baseline:** `02cc70a8b750de4bc88b740cf8a64f292a5c0325`.  
**סטטוס החבילה:** סקירה ותכנון בלבד; אין ממצא שסומן כמתוקן במסגרת PR זה.  
**מקור קובע:** [הדוח המלא](REPORT.he.md). רצף העבודה מופיע ב־[תכנית הביצוע](IMPLEMENTATION-PLAN.he.md).

## סיווגים

- `Reported / static`: התנהגות או מסלול כשל שמזוהים בסקירת קוד; לא שחזור Windows.
- `Lab reproduced`: שוחזר בתנאים מבודדים המפורטים בראיה בלבד.
- `Needs validation`: המלצה או סיכון הדורשים בדיקה נוספת.
- `Confirmed current`: המממש/בודק אימת על HEAD עדכני עם היקף ראיה מפורש.
- `Fixed, awaiting validation`: נכתב תיקון אך תנאי הקבלה לא הושלמו.
- `Verified fixed`: בדיקות הקבלה הנדרשות עברו וה־commit והראיות נקשרו לשורה.
- `Disproved / superseded`: הופרך או כבר תוקן; לצרף הסבר וראיות, לא למחוק את השורה.

`SKIPPED`, `BLOCKED` ו־`NOT RUN` אינם `PASS`. קריאת קוד אינה הרצת E2E, ו־Linux אינו אימות Windows.

## רישום התחלתי

| ID | טענה ממוקדת | ראיה זמינה | אימות שחסר / תנאי סגירה | חבילת עבודה | סטטוס תיקון |
|---|---|---|---|---|---|
| F01 | guard לקסיקלי אינו מבטיח שהיעד הפיזי נמצא ב־copy/staging | קוד R3/R8; probe מצורף ששוחזר ב־Linux | Windows junction/symlink/hard-link policy, שרשרת מלאה, יעדים חיצוניים ללא שינוי | A1 | לא תוקן במסגרת הסקירה |
| F02 | הסרה חלקית יכולה למחוק exe ו־state ולאבד מסלול ניהול לשאריות | זרימת uninstall, enumeration ו־GUI: R3/R5/R6 | נעילת non-exe, exe שנמחק, restart ומקור חסר; cleanup גלוי דרך UI | A2 | לא תוקן במסגרת הסקירה |
| F03 | Herdr מוחקת config/session פרטיים במסלול רגיל בניגוד להודעה הגנרית | prebuilt uninstall ו־UI: R3/R5/R9 | נתונים נשמרים בהסרה רגילה ובהתקנה מחדש; purge רק בהסכמה ובפרופיל פרטי מאומת | A3 | לא תוקן במסגרת הסקירה |
| F04 | Busy/Deferred והסרה מוסתרת אינם בעלי חוזה תוצאה אחיד | update ו־Start-AppUninstall: R3/R5/R6 | lock תפוס אינו הצלחה; worker failure/Partial מגיעים ל־UI; תוצאה עקבית בכל entry point | A4 | לא תוקן במסגרת הסקירה |
| F05 | שתי תקלות הורדה זמניות עלולות להינעל כ־ARTIFACT | סיווג הורדה ו־latch: R3/R9 | שתי נפילות רשת והתאוששות בלי Force; כשל integrity לא מותקן; כשל מבני מוגבל | A5 | לא תוקן במסגרת הסקירה |
| F06 | launcher ב־ASCII אינו שומר נתיבי משתמש בעברית | New-RtlLaunchScript: R3 | WSH/launcher בפועל, שם משתמש עברי, רווחים, OneDrive, shortcut/tray/GUI | A6 | לא תוקן במסגרת הסקירה |
| F07 | README אינו משקף את שינוי ה־fuse ואת החריגים לפרופיל/fork | README מול v2.5.0: R1/R3/R8/R9/R10 | טבלת שינויים מדויקת ומגבלות לפי חבילה; בלי הבטחות שלא נבדקו | A7 | לא תוקן במסגרת הסקירה |
| F08 | status כותב state; כתיבה אינה אטומית באופן עקבי; environment גלובלי הוא סיכון | R3/R6; חלקים ישירים וחלקם סיכון ארכיטקטוני | status טהור, crash recovery, מיגרציה, atomic writes ובידוד פעולות; אין race מאומת עדיין | C, ובסיס מוקדם ב־A | לא תוקן במסגרת הסקירה |
| F09 | prose toggle אינו מכסה leaf processing; טבלה מסומנת מדולגת; math משנה DOM מנוהל | renderer R7; W4/W5 להקשר | payload אמיתי, toggle/reuse/streaming/selection/undo; לא שוחזרה קריסת אפליקציית יעד | D | לא תוקן במסגרת הסקירה |
| F10 | חסר שער שחרור שנבדק מחדש; אריזה/checksum/asset matching צריכים הקשחה | R2/R3/R9/R11/R12; אפס Actions בעת הסקירה | CI ממשי, package מתוך SHA מוגדר, mandatory files, exact asset/checksum, upgrade/recovery | B | לא תוקן במסגרת הסקירה |

## שדות חובה בכל עדכון שורה

מזהה Fxx; HEAD שנבדק; source path ושורות או permalink; התרחיש; סביבה; פקודה; expected/actual; קישור ללוג או fixture מסונן; דרגת הביטחון; ההשפעה על המשתמש; החלטה; PR ו־commit של תיקון; בדיקת קבלה; סיכון שאריתי.

בממצא מורכב יש לפצל תתי־טענות. לדוגמה, ב־F08 כתיבת `.bad` בתוך status נראית בקוד, בעוד race בין runspaces הוא סיכון שלא שוחזר. אין לסמן את שניהם באותה דרגת הוכחה.

## תבנית לרשומת אימות

```text
Finding: Fxx
Reviewed baseline: 02cc70a8b750de4bc88b740cf8a64f292a5c0325
Current HEAD:
Code references:
Claim checked:
Environment / runtimes:
Fixture isolation:
Command:
Expected result:
Actual result:
Evidence path:
Status / confidence:
User impact:
Decision:
Implementation PR / commit:
Before-fix failure:
After-fix result:
Windows E2E status:
Residual risk / skipped checks:
```

## טיפול בסתירה לסקירה

ממצא שמופרך נשמר עם ראיה. ממצא שכבר תוקן מקושר לתיקון, ואינו מקבל עוד patch מיותר. טענה שאינה ניתנת לאימות מסומנת ככזו; אין להפוך אותה לדרישה גורפת או להכריז שהמערכת בטוחה בלי בדיקה.

בחירת WPF, גודל קבוצת הבטא, כמות adapters ויעדי ביצועים הם המלצות/החלטות, לא באגים ברשימת F01–F10. אין לסגור אותם כאילו היו בדיקות אוטומטיות שעברו.

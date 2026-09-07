# הקשר, הבחנות והמשך חקירה

מסמך משלים ל־[REPORT.he.md](REPORT.he.md). הוא שומר הבחנות שנדרשות להבנת הסקירה ותורי בדיקה שנובעים מהקוד שנקרא. אין כאן תוצאות Windows חדשות או טענה שכל השאלות להלן הן תקלות מאומתות.

## 1. לא ליישם מחדש את תכנית Codex הישנה באופן עיוור

ההקשר המקורי היה הסרה דרך האשף ותמיכה ב־Codex 26.901. הסקירה מתייחסת כבר למימוש ב־v2.5.0 ולא רק לתכנית. לכן הדרישה היא לתקן פערי אמינות שנשארו, ולא להחזיר כל פרט שהיה כתוב בתכנון מוקדם.

- שם הפונקציה `Invoke-CodexRtlUninstall` אינו מוכיח שהיא מסירה רק Codex. הקוד משתמש בפרופיל הפעיל; ביקורת צריכה לבדוק את הנתיבים וה־callers ולא להסיק מהשם בלבד.
- אין לדרוש checkbox למחיקת `%APPDATA%\\Codex` רק משום שהוא הוצע בתכנון מוקדם. כשפרופיל משותף או לא ידוע, שומרים אותו. F03 מתייחס בנפרד לנתונים הפרטיים של Herdr.
- סף של שתי תקלות מבניות הוא החלטת מנגנון מתועדת בקוד, לא הוכחה שהתכנית לא בוצעה. F05 מבקר את סיווג תקלות הרשת תחת ARTIFACT, לא את עצם קיום הסף.
- worker נפרד להסרה מהמגש אינו פסול כשלעצמו. הפער ב־F04 הוא ערוץ תוצאת סיום, טיפול בכשל ושאריות, ולא דרישה קשיחה לבחור runspace דווקא.
- אין להוסיף PE/hash manipulation שלא נחוץ למימוש שנבדק. שינוי fuse בעותק מחייב גילוי נאות והגנות, ואינו היתר לכתיבה במקור.

מקורות: [ליבת המנוע ב־baseline](https://github.com/ElazarKrispel/desktop-rtl-patch/blob/02cc70a8b750de4bc88b740cf8a64f292a5c0325/scripts/lib/desktop-rtl-lib.ps1), [המגש](https://github.com/ElazarKrispel/desktop-rtl-patch/blob/02cc70a8b750de4bc88b740cf8a64f292a5c0325/scripts/DesktopRtlTray.ps1), [האשף](https://github.com/ElazarKrispel/desktop-rtl-patch/blob/02cc70a8b750de4bc88b740cf8a64f292a5c0325/scripts/Install-DesktopRtlGui.ps1).

## 2. שאלות ממוקדות להמשך בדיקה מתוך הקוד שנקרא

אלה review leads משניים, לא F11–F14 מאומתים. אם בדיקה מאשרת בעיה יש לרשום ממצא נוסף עם מקור, תרחיש וסיכון, ולא להגניב שינוי scope לריפקטורינג.

### N01. מחיקת Registry לפי בעלות חלקית

ב־`Remove-RtlCopyShellRegistrations` יש candidate discovery, חילוץ exe ואימות שהוא תחת CopyRoot. יש לבדוק אם מחיקת מפתח האב כולו באמצעות `-Recurse` יכולה למחוק siblings/values שאינם בבעלות הכלי. ההערה על מחיקת CLSID אב רק כשהוא ריק צריכה להתאים לקוד ולא להחליף בדיקה. יש לבדוק בנפרד fallback מ־Icon כשאין command ברור, וכשלי discovery/הרשאות שלא נכנסים ל־Leftovers.

בדיקה מוצעת: CLSID/verb סינתטי עם command בבעלות הכלי וגם ערך/תת־מפתח שאינו שלו; נתיב המקור ונתיב בעל prefix דומה; command לא מצוטט עם רווחים או משתנה סביבה. הבדיקה אינה רשאית לסרוק ולמחוק רישומים אמיתיים של המשתמש.

מקור: [Remove-RtlCopyShellRegistrations](https://github.com/ElazarKrispel/desktop-rtl-patch/blob/02cc70a8b750de4bc88b740cf8a64f292a5c0325/scripts/lib/desktop-rtl-lib.ps1#L2537-L2594).

### N02. משמעות כשל אימות לאחר swap

מסלול ASAR לוכד כשל post-swap verification וממשיך לרישום state; מסלולי dir/inline מתנהגים אחרת. יש לאמת האם כשל זמני אכן נבדק שוב ב־poll הבא, או שמסלול AlreadyCurrent מדלג עליו. לא לטעון ל־rollback תקין בלי להזריק failure ולבדוק state, copy ובריאות לאחר restart.

מקור: [post-swap update path](https://github.com/ElazarKrispel/desktop-rtl-patch/blob/02cc70a8b750de4bc88b740cf8a64f292a5c0325/scripts/lib/desktop-rtl-lib.ps1#L2100-L2150).

### N03. precedence: Blocked מול Fresh/Repair

יש לבדוק failed first install או state חסר יחד עם blocked record תקף. הצגת Repair/Fresh כשה־Auto חסום עשויה להסתיר את סיבת הכשל. זו דוגמה לכך שבריאות התקנה ומצב עדכון הם ממדים נפרדים; יש לבדוק UI ולא רק helper של blocked.json.

מקור: [Get-CodexRtlStatus](https://github.com/ElazarKrispel/desktop-rtl-patch/blob/02cc70a8b750de4bc88b740cf8a64f292a5c0325/scripts/lib/desktop-rtl-lib.ps1#L1847-L1900).

### N04. השבתת מגש בזמן worker פעיל

ה־quit event וה־mutexים צריכים להיבדק מול worker שעדיין בונה staging, uninstall מאפליקציה אחרת, restart ו־self-update. בדיקת Set/Dispose של event לבדה אינה הוכחת lifecycle של תהליכים. יש לבדוק האם force-stop והמתנה ליציאה משאירים handles/locks או עבודה חלקית, בלי להניח race ששוחזר.

מקור: [Stop-RtlOwnedProcesses](https://github.com/ElazarKrispel/desktop-rtl-patch/blob/02cc70a8b750de4bc88b740cf8a64f292a5c0325/scripts/lib/desktop-rtl-lib.ps1#L2614-L2650) ו־[DesktopRtlTray.ps1](https://github.com/ElazarKrispel/desktop-rtl-patch/blob/02cc70a8b750de4bc88b740cf8a64f292a5c0325/scripts/DesktopRtlTray.ps1).

## 3. גבולות אסטרטגיים

המוצר מיועד לתמיכה בקריאה ובכתיבה בעברית בכלי AI קיימים, לא לתרגום מלא של הממשק ולא לניהול חשבונות AI. מודל AI יכול לשפר את תהליך הפיתוח; אינו נדרש בתוך מסלול שמחליט אילו קבצים למחוק או כיצד להתקין patch.

מעבר ל־WPF או Tauri אינו חוסך מעצמו את העתקת אפליקציות המקור. perf baseline צריך להפריד בין footprint המנהל, עלות copy/staging והשפעת ה־renderer. אין בדוח תוצאות benchmark או הערכת גודל שוק שמצדיקות מספרים מומצאים.

תוספים קיימים בדפדפן הם אינדיקציה לקיום קטגוריה בלבד, לא הוכחה לביקוש בהיקף מסוים. עדיף לבחון תוצאה שימושית והפחתת תמיכה ידנית לפני הרחבה.

## 4. מגבלות שצריכות להישאר גם בסיכום ל־ASTRA

- ההוכחה הסינתטית היא על extracted function, לא על כל התקנת Windows.
- metadata של release אינו אימות בתים של ZIP המוצר.
- דיווחי PR אינם בדיקות עצמאיות של הסוקר.
- תיאור framework ותיעוד upstream עשויים להשתנות: לבדוק אותם שוב בעת החלטת סטאק/חתימה/שחרור.
- אין כאן אישור משפטי לרישוי forks או לשינוי אפליקציות צד שלישי.
- PR המחקר אינו אישור לפרסום מוצר, להרצת בדיקות הרסניות או לשינוי סביבת העבודה של המשתמש.

# desktop-rtl-errors.ps1
# Maps the engine's coded error prefixes ([NOCODEX], [NODE], [ASAR], ...) to friendly
# Hebrew messages. Split out of the lib because the lib is ASCII-only; this file holds
# Hebrew literals and MUST stay UTF-8 WITH BOM. Dot-sourced by the lib at load time, so
# the GUI, the tray, the settings dialog and the CLI all share one implementation.

function Get-RtlHebrewError([string]$msg) {
    if (-not $msg) { return 'הפעולה נכשלה. ראה/י את הלוג למטה ושלח/י אותו למפתח.' }
    $appName = try { $script:ActiveProfile.DisplayName } catch { 'האפליקציה' }
    switch -Regex ($msg) {
        '^\[NOCODEX\]' { "$appName אינו מותקן. התקן/י אותו ואז לחץ/י ""בדוק שוב""." ; break }
        '^\[NODE\]'    { "מנוע ה-Node של $appName לא נמצא. ייתכן שהאפליקציה לא הותקנה במלואה או עודכנה. נסה/י לתקן את ההתקנה ואז לנסות שוב." ; break }
        '^\[LAYOUT\]'  { "$appName זוהה אך המבנה הפנימי שלו אינו כמצופה. ייתכן שהאפליקציה עודכנה ושהכלי צריך עדכון. עדכן/י את הכלי או פנה/י למפתח." ; break }
        '^\[FUSE\]'    { "בגרסה זו של $appName אימות ה-asar מופעל, ולכן שיטת ההעתקה אינה יכולה להחיל את התיקון. אנא דווח/י למפתח." ; break }
        '^\[ASAR\]'    { "עריכת קובץ האפליקציה (asar) נכשלה. נסה/י ""התקן מחדש""; אם התקלה חוזרת, ייתכן ש-$appName עודכן ושהכלי צריך עדכון, אנא שלח/י את הלוג למפתח." ; break }
        '^\[DISK\]'    { 'אין מספיק מקום פנוי בדיסק. פנה/י מספר GB ונסה/י שוב.' ; break }
        '^\[LOCK\]'    { "חלק מהקבצים נעולים (אולי אנטי-וירוס, סייר הקבצים, או ש-$appName (RTL) פתוח). סגור/י אותם ונסה/י שוב." ; break }
        '^\[AV\]'      { "הפעולה נחסמה כנראה על ידי האנטי-וירוס (Windows Defender). הכלי עורך רק עותק מקומי של $appName ואינו נוגע במקור. אפשר לאשר זמנית או להוסיף חריגה ולנסות שוב." ; break }
        '^\[PACKAGE\]' { 'חבילת ההתקנה חסרה קבצים. ודא/י שחילצת את כל ה-ZIP, לא רק את קובץ ה-cmd, ונסה/י שוב.' ; break }
        '^\[SAFETY\]'  { "הפעולה בוטלה מטעמי בטיחות (ניסיון לגעת בקובץ מחוץ לעותק ה-RTL). ההתקנה המקורית של $appName לא נפגעה." ; break }
        '^\[VERIFY\]'  { 'בדיקת התקינות שלאחר ההתקנה נכשלה: התיקון לא אומת בעותק. נסה/י "התקן מחדש". אם התקלה חוזרת, שלח/י את הלוג למפתח.' ; break }
        '^\[STAGING\]' { 'בניית העותק הזמני נכשלה או נותרה חלקית. נסה/י "התקן מחדש"; אם התקלה חוזרת, ודא/י שאף תוכנה (אנטי-וירוס, סייר הקבצים) לא נועלת את תיקיית ההתקנה, ונסה/י שוב.' ; break }
        '^\[INTEGRITY\]' { 'בדיקת ה-checksum של קובץ ההורדה נכשלה. ההורדה בוטלה ולא בוצע שום שינוי. נסה/י שוב; אם התקלה חוזרת, הורד/י מחדש מ-GitHub.' ; break }
        '^\[PROFILE\]' { 'שגיאה פנימית בבחירת האפליקציה. ודא/י שבחרת אפליקציה נתמכת (Codex או OpenCode) ונסה/י שוב.' ; break }
        '^\[CANCEL\]'  { 'הפעולה בוטלה.' ; break }
        default        { "הפעולה נכשלה. הפרטים נשמרו בקובץ הלוג, אנא שלח/י אותו למפתח.`r`n`r`n$msg" }
    }
}

# F07 ו־F10: תיעוד, אריזה ושרשרת הורדה

מקור הקוד: `02cc70a8b750de4bc88b740cf8a64f292a5c0325`. בדיקות PS רצות על Windows PowerShell 5.1.26100.9168. אין הרצת מתקין אמיתי או קובצי release. קובצי ZIP נקראים בזיכרון בלבד בבדיקת ההשוואה.

## F07: מאומת, ביטחון גבוה

README:23 מציג 285 KB. חבילת release שהורדה היא 1,026,766 בתים. README:225,329-330 טוען שרק app.asar נערך וש־integrity כבוי מראש, בעוד הפרופיל מגדיר `FuseFlipInCopy=true` ב־lib:269 וה־wrapper ב־831-865 מפעיל שינוי fuse בעותק. README:97-99,346-347 מכליל שיתוף חשבון ושיחות, בניגוד לנתוני Herdr הפרטיים המתועדים ב־README:300-309 וב־herdr:291-292,415-453. README:198 מכליל את payload לכל האפליקציות, בעוד Herdr הוא prebuilt. README:393 מכליל אי־הפצת קוד צד שלישי, בעוד התאמת Herdr מתקינה fork.

README:152-155,184 מציג אימות checksum ללא החריג של fallback ב־install.ps1:54-59. בנוסף, רשימת CLI ב־README:168 ובמפת הריפו אינה כוללת Herdr אף שה־ValidateSet כן כולל אותו. אלה אי־התאמות טקסט מול מימוש; אין צורך בהרצת GUI להוכיח אותן. לא ניתנה חוות דעת משפטית על הפצת fork, ולא אומתה רשימת notices של build Herdr.

הפתרון הוא טבלת שינויים ומדיניות מידע לכל adapter, גילוי שינוי integrity בעותק, היקף תאימות לפי גרסה וטקסט bootstrap מדויק. אין לכתוב 'אינו משנה מקור' כהוכחה שכל guard פיזי כבר נבדק. יש לשמור את ההבחנה בין מטרת copy-only לבין גבולות ההגנה שנבדקו.

## F10: תתי־ממצאים וראיות

| בדיקה | expected | actual | סיווג |
|---|---|---|---|
| Build-Release.ps1:26-28, עותק מלא במבנה חדש החסר src/launchers | אריזה נכשלת | exit 0 ונוצר ZIP | מאומת, בדיקת script מלא עם קבצי דמה |
| Test-RtlPackage:1099-1110, ארבעה קבצים סינתטיים בלבד | חבילה ללא GUI/tray/Herdr נדחית | true | מאומת, helper אמיתי בלבד |
| Get-RtlUpdateDecision:2850-2864, product.zip ואחריו debug-symbols.zip | בחירה חד־משמעית בחבילת המוצר | ה־ZIP האחרון ברשימה נבחר | מאומת, פונקציה טהורה עם metadata סינתטי |
| תנאי checksum ב־lib:2896 | digest ששויך לשם אחר נדחה | התנאי מקבל אותו | מאומת, הביטוי המקורי מה־AST בלבד |
| install.ps1:33-59, הורדת checksum נכשלת זמנית | כשל מפורש לפני extraction | בקשת fallback לארכיון source | מאומת, bootstrap מלא עם network/extraction/launch stubs |
| API Actions | לבדוק אם יש היסטוריית CI זמינה | total_count=0; אין .github/workflows בעץ | עובדה בזמן הבדיקה; אינה מוכיחה שלא רצו בדיקות מקומיות |
| בתים של ZIP v2.5.0 | digest וקובצי מקור תואמים | checksum תקין וכל התוכן תואם לבסיס, כמפורט להלן | פער אימות של הסקירה נסגר; לא E2E |

מסלול העדכון הוא tray/settings -> Test-RtlToolUpdateAvailable -> Get-RtlUpdateDecision -> Invoke-RtlSelfUpdate -> Test-RtlPackage -> Copy-RtlBin -> bin.staging -> מסלול preload של המגש. ב־Copy-RtlBin:2333-2349 כמה תלויות שהן כיום חלק מהתפקוד, ובהן Herdr וה־tray, עדיין optional. Test-RtlStagedBin:2692-2702 בודק רק ארבעה קבצים ו־parse של lib. לכן manifest של runtime נדרש צריך להיות משותף לאריזה, preload והעתקה, עם הפרדה מפורשת בין רכיב נתמך לרכיב optional היסטורי.

Herdr כבר בוחר שם asset מדויק ב־herdr:23,160. הבעיה שלו אינה כלל בחירת ה־ZIP האחרון. בדיקת checksum שלו ב־183-187 דומה לביטוי שאינו קושר שם, ולכן יש לשתף parser תקין לשלושת הצרכנים: bootstrap, self-update ו־Herdr. בחירת שם/ארכיטקטורה אינה מחליפה אימות תוכן, ו־checksum מאותו release אינו חתימת מוציא לאור עצמאית.

חידוד מעבר לדוח: fallback ב־bootstrap אינו מוגבל ל־404 של גרסה היסטורית. כל exception שאינו מתחיל ב־[INTEGRITY], לרבות timeout בהורדת checksum, מפעיל fallback. הבדיקה עצרה לפני extraction במתכוון. ההסקה היא שהקוד בהמשך יכול להפעיל תוכן שלא אומת; לא הורד או הורץ תוכן זדוני.

## בדיקת release לפי בתים

הורדו בקריאה בלבד שני assets של v2.5.0 דרך gh release download. תוצאות ב־[release-byte-validation.json](release-byte-validation.json); metadata ב־[release-metadata.json](release-metadata.json).

- ZIP SHA256: `f7a7e612ec3627c501291433a22a3e41ee4729711535e95a1c9e409f686db8e8`.
- hash תואם לשורת השם המדויקת ב־SHA256SUMS.txt וגם ל־digest ב־GitHub metadata.
- 38 קבצים: 11 byte-identical ל־Git blobs, 27 שונים רק ב־LF/CRLF. אין CONTENT_DIFFERS.
- כל 30 הקבצים הנכללים במדיניות Build-Release קיימים. שמונה נוספים: .gitattributes, .gitignore וששת קובצי tools.
- התיקייה העליונה היא desktop-rtl-patch-2.5.0; הקוד של Build-Release יוצר desktop-rtl-patch. שני המבנים נקראים דרך תיקייה ראשונה ב־bootstrap. הפער אינו מוכיח כשל פתיחה.
- metadata מציין immutable=false. אין מסקנה שנעשתה החלפה של release. פשוט אין אפשרות לייחס immutability לגרסה הזאת.

המסקנה המצומצמת: ZIP מאומת בתוכנו, אך אינו תואם במבנה וברשימת קבצים לפלט הצפוי של Build-Release הנוכחי. לא הוכחה בנייה שחוזרת לאותו ZIP byte-for-byte. אין להשמיט את החריגים ולהציג את כל 38 הקבצים כזהים בבתי הקובץ.

## פקודות ומגבלות

```powershell
powershell.exe -NoProfile -File docs/reviews/2026-09-07-independent-validation/packaging/probe-packaging.ps1
python docs/reviews/2026-09-07-independent-validation/packaging/verify-release.py
```

הבדיקה הראשונה מחלצת helpers ב־AST ואינה טוענת את הספרייה השלמה. Build-Release מועתק ללא שינוי ל־root סינתטי חדש; הפלט שלו אינו מוצר. Bootstrap משתמש ברשת מדומה, חסימת extraction וחסימת Start-Process. כל חמש הבדיקות סיימו `reproduced=true`, שהוא שחזור הכשל ולא PASS בטיחות של המוצר.

הבדיקה השנייה דורשת assets שהורדו ל־C:\rtl-audit-20260907-downloads; אינה מורידה בעצמה. היא קוראת ZIP בלי לחלץ או להריץ. בפיתוח fixture הראשון התגלו שתי הנחות שגויות של הבדיקה: scope של מערך בקשות ב־bootstrap, ושם התיקייה העליונה ב־ZIP. שתיהן תוקנו ב־fixture ונבדקו מחדש. הכשלים הראשוניים אינם תקלות מוצר נוספות.

NOT RUN: התקנת ה־ZIP על Windows נקי, upgrade/rollback מסוכן פעיל, אימות חתימה קריפטוגרפית נפרדת, ARM64, archive traversal/adversarial extraction, partial-download E2E. לא נטען שהבדיקה הקצרה מכסה אותם.

## המלצה

לפני בטא עצמאית: fail-closed בהורדה, manifest משותף מחייב, checksum parser של רשומה מדויקת, דחיית ambiguity, בדיקת version/layout אחרי extraction, בנייה ובדיקות מאותו SHA ו־artifact. CI מבודד הוא חלק מהתיקונים, לא פרויקט שדוחים לסיום GUI. חתימת מפרסם וחתימת עדכון מתוכננות כשלב הפצה מפורש; אין צורך להמתין להן כדי לסגור fallback או קובץ runtime חסר.

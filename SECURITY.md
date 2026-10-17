# مراجعة الأمان — KMS (الدفعة 13)

مراجعة ثابتة (Static) للكود والـ SQL + اختبارات اعتداء على نسخة Postgres محلية (`node supabase/tests/140_security_audit.mjs`).
**مش اختبار اختراق على الموقع الحي**، ومقدرتش أشوف إعدادات Supabase/Vercel/GitHub الفعلية عندك — فالجزء الثاني تحت (اللي بإيدك) مهم.

## اللي اتفحص وطلع سليم
- كل جداول `public` عليها RLS، و`anon` معندوش أي صلاحية على أي جدول، و`authenticated` عنده `SELECT` بس (كل الكتابة بتمر عن طريق دوال RPC بتفحص الصلاحية).
- مفيش أي دالة تطبيق متاحة لـ `anon`. كل دوال `SECURITY DEFINER` مثبّت عليها `search_path`، ومفيش SQL ديناميكي بيستخدم مدخلات المستخدم.
- المستخدم المعلّق (Pending) مبيشوفش أي بيانات ولا يقدر ينفّذ أي دالة.
- عزل المطابخ: مستخدم مطبخ مبيشوفش ولا بيكتب في مطبخ تاني (Ledger, Balances, Documents, Reports, Product Card).
- الـ Manager مفيش طريق يصعّد صلاحيته: مينفعش يعمل نفسه Admin، ولا يدّي مطبخ/صفحة مش عنده، ولا يلمس Manager تاني أو الـ Root.
- الـ Import: الـ Batch بتاع مستخدم مينفعش مستخدم تاني يملّاه أو يعمله Validate/Commit.
- مفيش مفاتيح سرية في الكود (الواجهة بتستخدم الـ anon/publishable key بس)، ومفيش `dangerouslySetInnerHTML` ولا `eval`، والـ OAuth callback مفيهوش Open Redirect.

## اللي اتصلّح في الدفعة 13 (Migration `021` + الكود)
| الخطورة | المشكلة | الإصلاح |
|---|---|---|
| عالية (حسب إعداد Supabase) | لو تسجيل الإيميل/الباسورد شغّال، حد ممكن يسجّل بإيميل مدعو كـ Admin (قبل ما صاحبه يدخل) ويستلم صلاحيته | الدعوات والـ Root بتتطبق بس لو الإيميل مؤكد (أو دخول بـ Google). غير كده بيبقى Viewer معلّق |
| متوسطة | الـ Manager كان يقدر يعطّل مستخدم من الـ API (المواصفات: للـ Admin بس) | اتمنع في الداتا بيز |
| متوسطة | CSV Injection: اسم منتج بيبدأ بـ `=` بيتنفّذ كمعادلة لما حد يفتح الـ CSV في Excel | بيتحط `'` قبل أي نص بيبدأ بـ `= + - @` |
| منخفضة | مفيش Security Headers (Clickjacking) | `X-Frame-Options` و`CSP frame-ancestors` و`nosniff` و`HSTS` وغيرها |
| منخفضة | `is_period_closed` كانت بتسرّب حالة قفل فترات أي مطبخ، وصلاحيات Sequences واسعة | اتقفلت |
| منخفضة | رفع ملف ضخم بيعلّق المتصفح | حد 15 MB |
| منخفضة | رسالة الخطأ في صفحة Login بتتعرض من الرابط | اتقصّت لـ 300 حرف (والنص escaped أصلًا) |
| — | دالة "مسح كل البيانات" + كلمة سرها (MD5 لـ 4 أرقام) كانت في الريبو | الزرار بقى مخفي افتراضيًا (`NEXT_PUBLIC_ENABLE_RESET=1` لإظهاره) + سكريبت يشيل الدالة `supabase/go-live/drop_reset_all_data.sql` |

## الدفعة 14 (Migration `022`)
- المستخدم اللي الـ Admin عطّله بقى **معلّم "Disabled by Admin"**: الـ Manager مبيشوفه ولا يوافق عليه (بيرجع للـ Admin بس). الـ Manager بيوافق على المعلّقين الجداد واللي تحته بس.
- المستخدمين المعطّلين قبل التحديث ده (اللي ليهم مطابخ أو صفحات) اتعلّموا تلقائيًا معطّلين بواسطة Admin.

## اللي لازم تعمله إنت (إعدادات برا الكود)
1. **GitHub: خلّي الريبو Private** (Settings ← General ← Danger Zone ← Change visibility). حاليًا Public وفيه بنية الداتا بيز كلها وإيميلات الـ Admin. الـ Private مجاني.
2. **Supabase ← Authentication ← Providers:** سيب **Google بس**، وطفّي Email (أو على الأقل سيب Confirm email شغّال). وطفّي أي Provider مش بتستخدمه.
3. **Supabase ← Authentication ← URL Configuration:** الـ Site URL = رابط الموقع الحقيقي، والـ Redirect URLs = رابط الموقع (+ localhost للتطوير) من غير wildcards.
4. **شغّل Migration `021`** في SQL Editor.
5. **قبل ما تشغّل النظام للناس:** (أ) لو عايز تمسح البيانات التجريبية آخر مرة: Vercel ← Environment Variables ← `NEXT_PUBLIC_ENABLE_RESET=1` ← Redeploy ← امسح ← احذف المتغير. (ب) شغّل `supabase/go-live/drop_reset_all_data.sql`.
6. **2-Step Verification** على حسابات Google/GitHub/Vercel/Supabase بتاعة الـ Admins (حساب Admin واحد مخترق = كل البيانات).
7. **Vercel:** الـ Preview Deployments تبقى محمية (Settings ← Deployment Protection) أو متضافش روابطها في Supabase Redirect URLs.
8. **Backups:** النسخة المجانية من Supabase مفيهاش Backups تلقائية. استخدم Backup ZIP من الصفحة بانتظام (أسبوعيًا مثلًا) واحتفظ بيه برا Supabase. الـ Restore لسه مؤجل.

## مخاطر معروفة ومقبولة (قرار منك)
- **أي حساب جوجل يقدر يسجّل** (بيفضل Pending ومبيشوفش حاجة). الـ Manager بيشوف اسم وإيميل المعلّقين عشان يوافق. لو عايز تقصرها على `@breadfast.com` قولي.
- `npm audit`: ثغرة في `postcss` جوه `next` (وقت البناء بس، مش بتتعرض لمدخلات المستخدمين). الحل بيحتاج ترقية Next لنسخة 16، هنأجلها لحد ما تستقر.
- مفيش Rate Limiting على الـ API غير حدود Supabase الافتراضية.

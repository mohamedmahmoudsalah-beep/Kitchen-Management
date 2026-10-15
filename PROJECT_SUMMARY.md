# ملخص مشروع Kitchen Management System (KMS) — آخر تحديث: الدفعة 12

**الهدف:** ERP صغير لمطابخ Breadfast (Plus Mall, Rehab, Maadi, NC7). بديل لمحاولة Apps Script القديمة اللي كانت بطيئة.
**التقنيات (قرار نهائي، كله مجاني):** Supabase (Postgres + Auth + RLS) + Next.js 15 / TypeScript على Vercel + تسجيل دخول Google. Excel وSheets للتصدير فقط.
**آخر تسليم:** `kms-batch12.zip` (المشروع الكامل). الـ migrations بالترتيب في `supabase/migrations`: `001` لحد `020`. الأوامر: `supabase/tests/run_tests.sh` (SQL على Postgres محلي)، `npx vitest run` (73 اختبار) + SQL على PGlite: `node supabase/tests/110_tests_batch9.mjs` و`120_tests_batch10.mjs` و`130_tests_batch11.mjs` (بعد `npm i --no-save @electric-sql/pglite`)، `npm run build` لازم ينجح قبل أي تسليم.

## الأدوار
- **Admin:** كل حاجة. الـ Root `mohamed.mahmoudsalah@breadfast.com` مينفعش يتعطل أو يتحذف.
- **Manager:** يدخل ويعمل Post وImport ويقفل الفترات ويعدّل المنتجات على مطابخه وصفحاته، ويوافق على Viewer/Kitchen User بحدود مطابخه. **مبقاش يعمل Reverse ولا تعديل سطر في مستند Posted (الـ Admin بس، الدفعة 12).** الحذف والتعطيل للـ Admin.
- **Kitchen User:** يدخل ويعمل Post ويستورد على مطبخه وصفحاته. مفيش Reverse ولا قفل فترات.
- **Viewer:** قراءة وتصدير.
- الدخول: أي حساب جوجل، بيبقى Pending لحد ما Admin/Manager يوافق ويدّيه مطابخه وصفحاته. الصلاحيات مفروضة بـ RLS.

## القواعد الأساسية
- كل حركة مستند (Draft ← Post) بتكتب في Stock Ledger للإضافة بس. الرصيد بالكيلو (الوحدة الأساسية) ومفيش سالب (قيد في الداتا بيز). التصحيح بـ Reverse، والـ Audit Log تلقائي.
- التكلفة بتتجمّد وقت الـ Post = `Cost Pr UOM`. المنتج: `Syt Code` فريد و`Generic Code` ممكن يتكرر. `Base Qty per Syt` = كود السيستم يساوي كام كيلو. كل شاشة بتعرض الكيلو وعدد أكواد السيستم.
- **Import:** الملف يتفحص كله وغلطة واحدة = ولا صف يتحفظ، الأخطاء برقم الصف، كل رفع لمطبخ واحد، وفي زرار Excel template. **الصفر مسموح في كل الصفحات** (بيتسجل في المستند ومفيش حركة؛ في التحويل السطر الصفري مبيتبعتش). الـ Syt Code المطابق تمامًا له أولوية على الـ Generic.
- **كود Generic بيطابق أكتر من حجم:** بتظهر قايمة تختار منها (آخر حجم اتشترى متختار تلقائيًا؛ لو الأحجام نفس الـ UOM والـ base بيتختار واحد تلقائيًا).
- **المشتريات بعد الـ Post:** الـ Reverse للـ Admin بس. **التاريخ الافتراضي = النهارده.**
- **الأسباب:** قايمة مشتركة لـ Waste وAdjustments (Missing, Overage, Damage, Expired, Count Correction, Merge)، والسبب إجباري.

## التحويلات والجرد
- التحويل: Send ← In Transit ← المستلم يأكد الكمية الفعلية ← الفرق Return Pending ← المرسل يأكد المرتجع أو "Not coming back". المستخدم يقدر يحوّل لأي مطبخ فعّال (الـ Branch فوق بيفضل على مطابخه بس). عدّاد التحويلات الواردة والمرتجعات في الـ Sidebar.
- الجرد (Closing): snapshot بتاريخ واحد، والفروق عن دفتر المخزن لحد التاريخ بتتسجل تلقائيًا تسوية Count Correction (جرد الشهر = Opening اللي بعده). إيقاف ترحيل الجرد للفترة اللي بعده للـ Admin بس. لو النقص هيخلي الرصيد الحالي سالب (فيه حركات بعد تاريخ الجرد) الخطأ بيظهر وقت الـ Validate برقم الصف.
- **مسح الجرد (Admin بس، حتى لو الفترة مقفولة):** بيمسح الجرد + تسوية فروقه والرصيد بيرجع، وبيتسجل في الـ Audit.

## قفل الفترات والأرشفة
- القفل **بشهور كاملة بس** (من شهر لأي شهر)، وقبله بينزّل كل صفحات المطبخ Excel وبعدها تأكيد. إعادة قفل فترة اتفتحت (Reopen) شغّالة.
- الفترة المقفولة: مفيش غير الـ Admin يضيف/يعدّل/يمسح فيها (حتى Draft)، والـ Admin بسبب override.
- **أرشفة ومسح شهور قديمة (Admin بس):** Check ← تنزيل كل الصفحات ← كتابة جملة تأكيد ← مسح. شهور كاملة قبل الشهر الحالي، مش لازم تكون مقفولة، ومفيش تحويل مفتوح. الرصيد بيتحفظ كمستند ترحيل `ARC-…` لكل مطبخ فالشهور الجديدة مبتتأثرش، والفترة بتتقفل تلقائيًا، وبيتسجل في `purge_log`.
- **Backup (Admin):** ZIP بالتاريخ فيه Excel لكل صفحة (صف لكل صنف) + تقارير Consumption وWarehouse Stock لكل مطبخ. فيه كمان نسخة خام CSV لكل الجداول (للطوارئ).
- **Delete all data (Admin + كلمة سر):** بيمسح كل البيانات والـ Logs ويرجّع الترقيم من 1 (بيفضل المستخدمين والمطابخ والأسباب). الدالة بتستخدم `delete ... where true` لأن Supabase مفعّل فيه `pg_safeupdate` وبيرفض DELETE من غير WHERE (migration `017`). **لازم يتشال قبل الإنتاج:** `drop function public.reset_all_data(text);`

## التقارير والشاشات
- **Group by Generic Code (Warehouse Stock + Consumption):** زرار مفعّل افتراضيًا بيجمّع كل Syt Codes اللي ليها نفس الـ Generic في صف واحد (الكميات بالكيلو بتتجمّع، والقيمة = مجموع كل حجم بتكلفته). الصف المجمّع بيعرض الكيلو بس (من غير pcs)، واسمه من آخر حجم اتشترى (`last_purchased_syt`) وإلا أول Syt بالترتيب. الـ Generic اللي ليه حجم واحد أو من غير Generic بيفضل صف عادي. لو الزرار اتطفى بيرجع التفصيل لكل Syt. الـ Export بيطلّع عمود `Syt Codes` بالأحجام المجمّعة. التجميع في الواجهة (`lib/group-generic.ts`) من غير تغيير في الـ RPCs.
- **Dashboard (الدفعة 10):** اختيار **All Kitchens** في الـ Dashboard بس (باقي الصفحات مطبخ واحد). كروت (Stock value, Purchases, Usage, Waste, In transit, Return pending, Last count) + كروت Low/Avg/High/Not set + رسومات بالأيام (Stock value, Usage & Waste, Purchases) على فترة From/To (حد أقصى 180 يوم) + Stock value بالفئة/بالمطبخ + Needs attention + Top 8. كل القيم @ current cost. **Usage اليومي = صرف المخزن (WH_TXN)** لأن الاستهلاك الحقيقي محتاج جرد (بيفضل في صفحة Consumption). RPCs: `dashboard_summary(null)` = كل المطابخ المتاحة، `dashboard_trend`.
- **Low Stock (صفحة جديدة `low_stock` في Reports):** رصيد لايف لكل مطبخ من غير فلتر تواريخ. لكل مطبخ شيت لوحده: `Code | Low Stock | High Stock` (بالكيلو). الحالة: الرصيد <= Low = Low، >= High = High، وبينهم Avg، ومن غير حدود Not set. الحدود على مستوى الـ Generic (أو Syt لو مفيش Generic) فكل الأحجام بتتجمّع. الرفع: Validate ثم Save (غلطة واحدة = ولا صف، الأخطاء برقم الصف)، وضعين: Add & update أو Replace all. Excel template بالأصناف الحالية. الجدول `stock_levels` (Audit + Backup + بيتمسح في reset). **الصفحة لازم تتدّي للمستخدمين من Access Control** (الـ Admin بيشوفها تلقائي).
- **(الدفعة 12) السرعة:** جلسة الصفحة بقت طلب واحد `my_session()` بدل 4، والتحقق من التوكن محلي (`getClaims`) في الـ middleware والـ layout. Loading skeleton (`app/(app)/loading.tsx`)، و`staleTimes.dynamic = 30`. Cache قصير في المتصفح للـ Dashboard والتقارير وLow Stock (`lib/cache.ts`: أحدث من 45 ثانية بيتعرض من غير طلب، وأقدم بيتعرض فورًا وبيتحدّث في الخلفية) وأي كتابة (RPC مش قراءة) بتمسحه، وفي زرار Refresh. **لازم Vercel Function Region = أقرب Region لـ Supabase.**
- **تعديل سطر واحد في مستند Posted (الدفعة 11، للـ Admin بس من الدفعة 12):** في Purchases / Warehouse Txn / Waste / Adjustments / Opening / Closing، لما تفتح المستند بيظهر زرار **Edit** لكل سطر: تغيّر الكمية أو المنتج أو السبب/الاتجاه (التسويات) أو الملاحظة، أو **Zero this line**، وسبب التعديل إجباري. الـ Ledger بيتصلّح بحركة فرق بتاريخ المستند (مش بتتعدّل حركة قديمة) والرصيد مبيبقاش سالب (الخطأ واضح). الجرد: الكمية بس، وتسوية فرق المنتج ده (Count Correction) بتتعدّل معاه. **التحويلات مفيهاش تعديل سطر** (بتتقفل بالاستلام والمرتجع). نفس صلاحيات الـ Reverse: Admin/Manager على مطابخه، والمشتريات للـ Admin بس، والفترة المقفولة Admin بس. بيتسجل في `document_line_edits` (قبل/بعد، مين، ليه) ويظهر "edited" وسجل التعديلات تحت السطور. `edit_document_line`.
- **أرشفة ومسح بمطبخ محدد (الدفعة 11):** اختيار Kitchen (مطبخ أو All kitchens). مطبخ واحد = مستنداته ماعدا **التحويلات بين المطابخ** (بتفضل، وبتتمسح من All kitchens). الترحيل (ARC) والقفل التلقائي للمطبخ ده بس، وجملة التأكيد فيها كود المطبخ: `PURGE 2026-01 → 2026-03 @ MAADI`. **مسح بيانات صفحة (Admin):** Import Errors لمطبخ أو الكل، وممكن الأقدم من X يوم، وجملة التأكيد `CLEAR import_errors @ ALL|CODE`. الصفحات اللي وراها أرصدة بتتمسح بالأرشفة بالشهور. `purge_preview/purge_range(…, p_kitchen)`, `page_data_preview`, `purge_page_data`.
- **إصلاح:** Edit في Data Product كان بيفضل على داتا أول منتج اتفتح؛ دلوقتي كل Edit بيفتح الفورم بداتا المنتج المضغوط عليه.
- Consumption = Opening + Purchases + Transfer In − Transfer Out − Closing − Waste. Warehouse Stock = Opening + Purchases + Confirmed Transfer In − Transfer Out − Warehouse Txn − Waste + Adjustments. Dashboard: قيمة المخزون وقايمة Needs attention.
- **Export (Excel + CSV) على كل صفحات المستندات:** صف لكل صنف (Doc No, Date, Status, Lines, Note + المنتجات) ويطلّع كل المستندات المطابقة مش بس اللي على الشاشة.
- قوايم المستندات: 100 في المرة + Load more + بحث (Doc No / ملاحظة / كود أو اسم منتج) + فلتر الحالة.
- **Audit Log:** Change log + **Product Card** (كل حركة على منتج بالترتيب الزمني، + / −، الكمية بالكيلو والقطع، الرصيد بعدها، ومين عملها).
- لوجو Breadfast في `public/breadfast-logo.png` (Sidebar وتسجيل الدخول والانتظار والـ favicon).

## اللي اتأجل (المستخدم قرر نوقفه)
Restore من الـ Backup، Backup الخام على أجزاء، طباعة إذن التحويل، حد أدنى للمخزون وتنبيهه.

## ملاحظات تشغيل
- النسخة المجانية: 500 MB داتا بيز (بتتحول Read-only لو عدّت)، 5 GB Egress في الشهر، مفيهاش Backups تلقائية، والمشروع بيقف بعد 7 أيام من غير استخدام. تقدير تقريبي: ~8 KB لكل مستند (مع الـ Audit)؛ راقب الحجم من Reports ← Database.
- الاختبارات على كود الواجهة وPostgres محلي؛ الواجهة نفسها لسه بتتجرّب على Supabase الحقيقي، فأي شكل مختلف اتصوّره وابعته.
- الـ migrations بتتشغّل يدويًا في SQL Editor بالترتيب (New ← الصق ← Run). التحقق من آخر migration: ابحث بـ `to_regclass`/`pg_proc` (مثلًا `reset_all_data` للـ 016).

## أسلوب الشغل المفضّل
ردود بالعامية المصرية، خدمات مجانية بس، تسليم دفعات بـ ZIP كامل بعد كل دفعة، القرارات تتسأل صراحة مش تتاخد بصمت، `npm run build` والـ TypeScript لازم ينجحوا قبل التغليف، التنفيذ الأول وبعدين الشرح.

# Kitchen Management System — الدفعات 1 و 2 و 3 (+ 3.1)

الأساس + Auth + Data Product + Import (مجاني بالكامل: Supabase Free + Next.js على Vercel).

## 1) Supabase
1. اعمل Project جديد (Free).
2. **SQL Editor**: شغّل الملفات بالترتيب من `supabase/migrations/`:
   `001_foundation.sql` ← `002_stock_engine.sql` ← `003_import.sql` ← `004_grants.sql` ← `005_data_product_v2_reasons.sql` ← `006_batch2_entry_transfers_closing_reports.sql` ← `007_batch3_closing_opening_writeoff_transfers_import.sql` ← `008_open_signup_manager_approval.sql` ← `009_batch4_transfer_targets_purchase_lock_opening_zero_product_card.sql` ← `010_batch4_1_zero_everywhere_closing_carry_admin.sql` ← `011_batch5_documents_search.sql` ← `012_batch6_month_locks_archive_purge.sql` ← `013_batch7_import_code_priority_closing_validation.sql` ← `014_batch7_1_purge_without_lock_delete_closing.sql`
   - لو كنت شغّلت لحد 013: شغّل `014` بس. لو لحد 012: `013` ثم `014`. لو لحد 011: `012` ثم `013`. لو لحد 010: `011` ثم `012`. لو لحد 009: `010` ثم `011`. ولو لحد 008: `009` ثم `010` ثم `011`.
   - لو كنت شغّلت لحد 007 قبل كده: شغّل `008` بس (بيحدّث الموجود ومش بيمسح داتا).
   - `005` لحد `008` بيعيدوا تطبيق الـ grants في آخرهم، فمفيش داعي تشغّل 004 تاني.
3. **Authentication → Providers**: فعّل **Google** (محتاج OAuth Client من Google Cloud Console).
   - Redirect URL في Google Cloud: `https://<project>.supabase.co/auth/v1/callback`
4. **Authentication → URL Configuration**: ضيف الـ Site URL و `https://<your-app>/auth/callback` في Redirect URLs (وكمان `http://localhost:3000/auth/callback` للتجربة).
5. **Authentication → Providers → Email**: عطّل Sign ups بالإيميل/الباسورد (الدخول بجوجل بس).
6. أول دخول بـ `mohamed.mahmoudsalah@breadfast.com` بيتعمل له Admin أساسي تلقائيًا (مينفعش يتعطل أو يتحذف).
7. **أي حساب جوجل** يقدر يسجّل (مش شرط breadfast)، بس بيتعمله Profile **غير Active** وميشوفش ولا يعمل أي حاجة لحد ما **Admin أو Manager** يوافق عليه من **Access Control** ويدّيله مطابخه وصفحاته. في Google Cloud خلّي الـ OAuth consent screen **External** (ولما تجهز اضغط Publish app عشان مفيش حد Test users).
   - الـ Manager يوافق على المعلقين ويدّيهم Viewer أو Kitchen User بس، على **مطابخه وصفحاته هو بس**، ومبيلمسش مطابخ/صفحات المستخدم اللي برا نطاقه. تعيين Manager/Admin للـ Admin بس.

> Supabase Free بيعمل Pause بعد 7 أيام من عدم الاستخدام وملوش Backups تلقائية → صدّر بياناتك دوريًا (كل صفحة فيها Export).

## 2) تشغيل محلي
```bash
cp .env.local.example .env.local   # حط URL و anon key من Settings → API
npm install
npm run dev        # http://localhost:3000
npm run build      # لازم ينجح قبل أي تسليم
npm test           # اختبارات الـ Import/التحويل (vitest)
```

## 3) Vercel
Import الـ repo، وضيف المتغيرين `NEXT_PUBLIC_SUPABASE_URL` و `NEXT_PUBLIC_SUPABASE_ANON_KEY` (أو `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY`).

## 4) اختبار الـ SQL (اختياري)
على Postgres محلي (من غير Supabase): `PGUSER=postgres supabase/tests/run_tests.sh`
بيشغّل الـ migrations على stub لـ `auth` ويختبر: دومين الإيميل، حماية الـ Root، RLS بين المطابخ، الـ Import (all-or-nothing)، UOM، الرصيد السالب، تجميد التكلفة، قفل الفترات، Reverse، Audit.

## بنية الشغل
- **كل الكتابة بـ RPCs** (`import_*`, `post_document`, `reverse_document`, `set_user_access`, `close_period`…)؛ الجداول قراءة بس عبر RLS.
- **Stock Ledger append-only**، والأرصدة في `stock_balances` عليها `CHECK (qty_base >= 0)`.
- **كل مطبخ = Location مخزون واحد** (WAREHOUSE). `IN_TRANSIT` و`RETURN_PENDING` محجوزين للتحويلات (الدفعة 2).
- Schema جاهز لـ V2: `odoo_po_id`, `odoo_ref`, `odoo_po_line_id`, `qty_ordered_base`.

## تصليح 7.2 (واجهة فقط، مفيش Migration جديدة)
- **اختيار الحجم في الـ Import**: كان فيه عيب في قراءة الكود من الصف فالقايمة مكنتش بتظهر. اتصلّح وبقى متغطي باختبار على ملف حقيقي. القايمة بتظهر تحت الملف قبل Validate، وآخر حجم اتشترى متختار تلقائيًا.

## الدفعة 7.1 (014)
- **مسح الجرد (Admin بس)**: زرار Delete على صفحة Closing، حتى لو الفترة مقفولة. بيمسح الجرد + تسوية فروقه + أي Reverse مرتبط، والرصيد بيرجع زي ما كان، وبيتسجل في الـ Audit. بيرفض لو فيه حركات بعده اعتمدت على التسوية (كان هيخلي الرصيد سالب).
- **مسح الشهور القديمة**: مبقاش لازم الفترة تتقفل الأول. الـ Admin بيقرر (بعد تنزيل الصفحات)، والمسح بيقفل الفترة تلقائيًا في كل المطابخ.

## الدفعة 7 (013)
- **Import**: الـ Syt Code المطابق تمامًا بيتاخد الأول (حتى لو هو نفسه Generic لمنتج تاني)، فاختيار الحجم من القايمة بيشتغل. القايمة نفسها (آخر حجم اتشترى متختار تلقائيًا) في الدفعة 6.
- **Import الجرد (Closing)**: لو الجرد هيعمل تسوية نقص أكبر من الرصيد الحالي (يعني فيه حركات بعد تاريخ الجرد خلّصت الكمية)، الخطأ بيظهر وقت الـ Validate برقم الصف ورسالة بتشرح السبب، بدل ما يفشل وقت الحفظ.

## الدفعة 6 (012)
- **التاريخ الافتراضي = النهارده** في كل مستند جديد (وتقدر تعدله).
- **قفل الفترات بشهور كاملة بس** (من أول يوم لآخر يوم، ومن شهر لأي شهر). قبل القفل بينزّل كل صفحات المطبخ للفترة Excel، وبعدها بيطلب تأكيد.
- **الفترة المقفولة**: مفيش حد غير الـ Admin يضيف/يعدّل/يمسح فيها (حتى Draft، حتى لو غيّر التاريخ). الرسالة: الفترة مقفولة، ارجع للـ Admin. الـ Admin بيعدّل بسبب (override reason).
- **Backup الصفحات بالتاريخ** (Import/Export): ZIP فيه نفس ملفات الـ Export (صف لكل صنف) لكل الصفحات + Consumption وWarehouse Stock لكل مطبخ. الـ Backup الخام لجداول الداتا بيز بقى للطوارئ بس.
- **أرشفة ومسح شهور قديمة (Admin)**: Check ← تنزيل كل الصفحات ← كتابة جملة التأكيد ← مسح. الشروط: شهور كاملة قبل الشهر الحالي، مقفولة في كل مطبخ فيه حركة، ومفيش تحويل مفتوح أو Reverse مرتبط من برا الفترة. الرصيد بيتحفظ كمستند ARC-… لكل مطبخ، فالأرصدة وتقارير الشهور الجديدة مبتتأثرش (متجرّب بالاختبارات). بيتسجل في `purge_log`.
- **Product Card**: الحركات بالترتيب الزمني (التاريخ ثم وقت التسجيل) والرصيد بعد كل حركة بنفس الترتيب.
- **Import بالمشتريات (وباقي الصفحات)**: لو الـ Generic Code بيطابق أكتر من حجم، بتظهر قايمة تختار منها، وآخر حجم اتشترى متختار تلقائيًا — من غير ما ترفع الملف من جديد.

## الدفعة 5 (011)
- **قوايم المستندات والتحويلات من غير حد 500**: ترقيم صفحات (100 في المرة + Load more) وبحث بالـ Doc No / الملاحظة / كود أو اسم منتج + فلتر الحالة. الـ Export بيطلّع كل المستندات المطابقة مش بس اللي على الشاشة.
- **عدّاد في الـ Sidebar على Kitchens Transfer**: تحويلات واردة مستنية استلام + مرتجعات معلّقة.
- **Backup للـ Admin** (Import/Export ← Backup): ZIP فيه CSV لكل الجداول. النسخة المجانية مفيهاش Backups تلقائية — اعمله أسبوعيًا واحتفظ بالملف بره النظام.

## الدفعة 4 (009)
- **Kitchens Transfer**: المستخدم يقدر يحوّل لأي مطبخ فعّال (الـ Branch فوق بيفضل على مطابخه بس)، وأسماء المرسل/المستلم بتظهر صح.
- **Product picker**: القايمة بتظهر فوق الجداول (مبتتقصش)، بتعرض الكود والـ Generic والاسم وعدد الكيلو في كود السيستم، وبتشتغل بالأسهم و Enter.
- **Export (Excel + CSV) لكل صفحات المستندات** (Purchases, Waste, Closing, Adjustments, Warehouse Txn, Opening, Kitchens Transfer): صف لكل صنف مع Doc No / Date / Status / Lines / Note.
- **المشتريات بعد الـ Post**: Reverse/تعديل للـ Admin بس (مفروض في الـ DB).
- **الصفر في الـ Import مسموح في كل الصفحات** (010): السطر بيتسجل في المستند ومفيش حركة على الرصيد (في التحويل السطر الصفري مبيتبعتش). السالب لسه مرفوض (إلا Adjustments بالإشارة).
- **ترحيل الجرد للفترة اللي بعده** (Apply count variances) إيقافه للـ Admin بس؛ غيره بيترحّل تلقائيًا.
- **Audit Log → Product Card**: اختار منتج وشوف كل حركة (زيادة/نقص، الكمية بالكيلو والقطع، الرصيد بعدها، مين عملها)، مع Export.
- **اللوجو**: حط ملف اللوجو في `public/breadfast-logo.png` (بيظهر في الـ Sidebar وتسجيل الدخول وصفحة الانتظار والـ favicon).

## الدفعة 3
- **الجرد = Opening الفترة اللي بعدها** (جرد يناير = Opening فبراير): لما تعمل Post لجرد، الفرق بين الكمية المجرودة ورصيد الدفتر (لحد تاريخ الجرد) بيتسجل تلقائيًا كتسوية **Count Correction** مربوطة بالجرد، فرصيد المخزن = الجرد، وأي فترة بعدها بتبدأ منه. ممكن تقفل الخيار ده وقت الـ Post. Reverse للجرد بيعكس تسوية فروقه معاه. المنتجات اللي مش في الجرد مش بتتعدل في المخزون (بس بتتحسب Closing = 0 في تقرير الاستهلاك)، استخدم "Load stock list" عشان تجرد كل حاجة.
- **مرتجع ما رجعش فعلًا**: في Confirm return فيه زرار "Not coming back → return to stock & book as Missing": بيرجّع الكمية المعلقة استوك عند المرسل وبينزّلها Missing (تسوية نقص) في خطوة واحدة، والتحويل بيتقفل `CLOSED_PARTIAL`.
- **Import للتحويلات**: بيتم من المطبخ المرسل (المختار فوق)، وعمود `To` = المطبخ المستلم (الصفوف بنفس التاريخ والمستلم بتتجمّع في تحويل). التحويل بيتبعت In Transit والمستلم يأكد الكمية الفعلية من صفحته.
- **قالب Excel مثال في كل Import**: زرار "Excel template" في صفحة Import وفي كل صفحة ليها Import (Opening, Purchases, Warehouse Transactions, Waste, Adjustments, Closing, Transfers, Data Product). الملف فيه صفوف مثال من منتجاتك الفعلية + شيت Notes بشرح كل عمود (والاختبارات بتتأكد إن كل قالب الـ Importer بيقبله).
- **Dashboard** حقيقي (قيمة المخزون، In Transit، المرتجع المعلق، آخر جرد، وقايمة "Needs attention") + **قفل الفترات** من صفحة Closing (Close للـ Admin/Manager، Reopen للـ Admin بسبب).

## الدفعة 2
- **إدخال يدوي (Draft ← Post)** في Purchases / Warehouse Transactions / Waste / Stock Adjustments / Closing: التاريخ + سطور (منتج بالبحث بالكود أو الاسم). كل سطر بيعرض **الرصيد المتاح** والكمية بالوحدة الأساسية وبعدد أكواد السيستم مع بعض، وبيتمنع الـ Post لو الكمية أكبر من المتاح (والـ DB بيرفض برضو). Opening Balance بيتم رفعه Import بس.
- **Kitchens Transfer**: المرسل يعمل Transfer ← الكمية تخرج منه وتروح **In Transit** ← المستلم يأكد الكمية الفعلية ← الفرق بيفضل **Return Pending** عند المرسل ← المرسل يأكد المرتجع (على دفعات) ← `COMPLETED` أو `CLOSED_PARTIAL`. المرسل (Manager/Admin) يقدر يلغي تحويل لسه ما اتستلمش.
- **Closing / Stock Count**: جرد كـ snapshot (مش حركة في الـ Ledger) بتاريخ واحد، الصفر مسموح، وفيه Import. زرار "Load stock list" بيملا قايمة الجرد بالمنتجات اللي ليها رصيد.
- **Warehouse Stock** = Opening + Purchases + Confirmed Transfer In − Transfer Out − Warehouse Transactions − Waste + Adjustments.
- **Consumption** = Opening + Purchases + Transfer In − Transfer Out − Closing − Waste. الـ Closing = آخر جرد Posted تاريخه داخل الفترة، والحركات بتتحسب لحد تاريخ الجرد، والمنتج اللي مش في الجرد Closing = 0، ولو مفيش جرد كله 0 (بيظهر تنبيه). أي منتج ظهر في Opening/Purchases/Transfers/Closing بيظهر.
- **Opening للفترة** = رصيد المخزن قبل From (وبعد تطبيق فروق الجرد = آخر جرد) + أي رصيد افتتاحي مرفوع داخل الفترة. **Transfer Out** = المحوّل ناقص المرتجع المؤكد (يعني المرتجع المعلق بيفضل Transfer Out).
- المعادلتين مكتوبين مرة واحدة في SQL: `report_warehouse_stock` و`report_consumption` (والاختبارات بتتأكد إن Warehouse Stock = رصيد الـ Ledger الفعلي).
- **Waste**: السبب بقى إجباري (من القايمة المشتركة).

## Data Product (الأعمدة والمفتاح)
- أعمدة الملف: `Syt Code, Generic Code, Product Name, UoM, Product/Financial Category, Cost, Cost Pr UOM` + عمود **`Base Qty per Syt`** (كود السيستم الواحد = كام كيلو/وحدة أساسية). عمود `UoM` وصف بس ومش بيتحسب منه حاجة.
- `Cost` = تكلفة كود السيستم، و`Cost Pr UOM` = تكلفة الكيلو/الوحدة الأساسية (دي اللي بتتجمّد في الـ Ledger). لو اتكتب واحد بس يتحسب التاني بالـ Base Qty. لو الاتنين مش متسقين مع الـ Base Qty يظهر تنبيه ⚠ جنب Cost.
- المفتاح: `id` (uuid) هو الـ PK الداخلي لكل العلاقات، و`Syt Code` مفتاح العمل الفريد اللي بيتطابق بيه الاستيراد (ينفع يتعدّل لاحقًا من Edit من غير ما يبوّظ الحركات).
- من الصفحة: **Add product** / **Import file** (إضافة + تحديث) / **Update from file** (تحديث بس)، وفي الـ Wizard ممكن تختار "إضافة بس". الإدارة للـ Admin والـ Manager، والحذف والتعطيل للـ Admin بس (والحذف للمنتج غير المستخدم).

## الأسباب (Waste + Stock Adjustments)
- قايمة واحدة: Missing, Overage, Damage, Expired, Count Correction, Merge. لكل سبب اتجاه (Increase / Decrease / Either) بيحدد إشارة الكمية.
- أي مستخدم (مش Viewer) عنده صفحة Waste أو Stock Adjustments يقدر يضيف سبب من زرار **Add reason**. التعطيل للـ Admin بس.
- Adjustments: السبب إجباري. Waste: السبب اختياري (لكن لو اتكتب لازم يكون في القايمة وبسبب نقص/Either).

## قواعد الـ Import
- كل رفع لمطبخ واحد (المختار فوق) — Data Product عام.
- الأعمدة بالاسم والترتيب مش مهم والزيادة بتتجاهل. Tx: `Date, Code, Qty` (+ `Qty Pieces` / `Qty Base` / `Reason` / `Note`). **`Qty` بالكيلو (الوحدة الأساسية) افتراضيًا**، وتقدر تغيّره وقت الرفع لـ "عدد أكواد السيستم".
- الكود: Syt أو Generic. لو مش موجود أو بيطابق أكتر من منتج → خطأ. Generic ممكن يتكرر، Syt فريد.
- لا Partial Import: خطأ واحد = ولا صف. الأخطاء برقم الصف والسبب في **Import Errors**.
- الرصيد الافتتاحي: واحد فعّال لكل مطبخ، بتاريخ واحد، منتج مرة واحدة.
- Adjustments: `Reason` من القايمة وإشارة الكمية حسب اتجاه السبب.

# Kitchen Management System — الدفعات 1 و 2 و 3

الأساس + Auth + Data Product + Import (مجاني بالكامل: Supabase Free + Next.js على Vercel).

## 1) Supabase
1. اعمل Project جديد (Free).
2. **SQL Editor**: شغّل الملفات بالترتيب من `supabase/migrations/`:
   `001_foundation.sql` ← `002_stock_engine.sql` ← `003_import.sql` ← `004_grants.sql` ← `005_data_product_v2_reasons.sql` ← `006_batch2_entry_transfers_closing_reports.sql` ← `007_batch3_closing_opening_writeoff_transfers_import.sql`
   - لو كنت شغّلت لحد 006 قبل كده: شغّل `007` بس (بيحدّث الموجود ومش بيمسح داتا).
   - `005` و`006` و`007` بيعيدوا تطبيق الـ grants في آخرهم، فمفيش داعي تشغّل 004 تاني.
3. **Authentication → Providers**: فعّل **Google** (محتاج OAuth Client من Google Cloud Console).
   - Redirect URL في Google Cloud: `https://<project>.supabase.co/auth/v1/callback`
4. **Authentication → URL Configuration**: ضيف الـ Site URL و `https://<your-app>/auth/callback` في Redirect URLs (وكمان `http://localhost:3000/auth/callback` للتجربة).
5. **Authentication → Providers → Email**: عطّل Sign ups بالإيميل/الباسورد (الدخول بجوجل بس).
6. أول دخول بـ `mohamed.mahmoudsalah@breadfast.com` بيتعمل له Admin أساسي تلقائيًا (مينفعش يتعطل أو يتحذف). أي إيميل مش `@breadfast.com` بيترفض من الـ DB نفسه.

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

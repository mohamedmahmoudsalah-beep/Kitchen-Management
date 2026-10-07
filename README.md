# Kitchen Management System — الدفعة 1

الأساس + Auth + Data Product + Import (مجاني بالكامل: Supabase Free + Next.js على Vercel).

## 1) Supabase
1. اعمل Project جديد (Free).
2. **SQL Editor**: شغّل الملفات بالترتيب من `supabase/migrations/`:
   `001_foundation.sql` ← `002_stock_engine.sql` ← `003_import.sql` ← `004_grants.sql` ← `005_data_product_v2_reasons.sql`
   - لو كنت شغّلت 001–004 قبل كده: شغّل `005` بس (بيحدّث الموجود ومش بيمسح داتا).
   - `005` بيعيد تطبيق الـ grants في آخره، فمفيش داعي تشغّل 004 تاني.
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

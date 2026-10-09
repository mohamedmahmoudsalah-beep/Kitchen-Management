-- اختبارات الـ migrations. بتتشغل بـ run_tests.sh (superuser) وبتبدّل الـ role لـ authenticated.
\set ON_ERROR_STOP on
\set QUIET on
create schema testh;
grant usage on schema testh to public;

create function testh.login(p_email text) returns void language plpgsql as $$
declare v uuid;
begin
  select id into v from auth.users where lower(email) = lower(p_email);
  perform set_config('request.jwt.claim.sub', coalesce(v::text, ''), false);
  execute 'set role authenticated';
end $$;

create function testh.logout() returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub', '', false);
end $$;

-- بيتأكد إن الـ SQL بيفشل وفيه الرسالة المتوقعة
create function testh.expect_err(p_sql text, p_like text) returns void language plpgsql as $$
begin
  execute p_sql;
  raise exception 'EXPECTED ERROR LIKE [%] BUT SUCCEEDED: %', p_like, p_sql;
exception when others then
  if sqlerrm like 'EXPECTED ERROR LIKE%' then raise; end if;
  if sqlerrm not like p_like then
    raise exception 'WRONG ERROR. wanted like [%], got [%] for: %', p_like, sqlerrm, p_sql;
  end if;
end $$;

create function testh.assert_eq(p_name text, p_actual anyelement, p_expected anyelement) returns void language plpgsql as $$
begin
  if p_actual is distinct from p_expected then
    raise exception 'FAIL [%]: expected %, got %', p_name, p_expected, p_actual;
  end if;
  raise notice 'ok  - %', p_name;
end $$;

-- مساعد: يرفع Batch كامل (start + stage + validate) ويرجّع id
create function testh.stage(p_module text, p_kitchen uuid, p_rows jsonb, p_mode text default 'PIECE', p_override text default null, p_import_mode text default 'upsert')
returns uuid language plpgsql as $$
declare v_b uuid; v_arr jsonb;
begin
  v_b := public.import_start(p_module, p_kitchen, 'test.xlsx', jsonb_array_length(p_rows), p_mode, p_import_mode);
  select jsonb_agg(jsonb_build_object('row_no', ord, 'data', e)) into v_arr
    from jsonb_array_elements(p_rows) with ordinality as t(e, ord);
  perform public.import_stage_rows(v_b, v_arr);
  perform public.import_validate(v_b, p_override);
  return v_b;
end $$;

-- ===================== 1) Auth / profiles =====================
insert into auth.users (email) values ('mohamed.mahmoudsalah@breadfast.com');
insert into auth.users (email) values ('Ali@Breadfast.com');
select testh.assert_eq('root profile is active admin',
  (select role::text || is_active::text || is_root::text from public.profiles where email = 'mohamed.mahmoudsalah@breadfast.com'),
  'admintruetrue');
select testh.assert_eq('unregistered user -> inactive viewer profile',
  (select role::text || is_active::text from public.profiles where email = 'ali@breadfast.com'), 'viewerfalse');
-- أي دومين يقدر يسجّل، بس بيتعمله Profile غير Active (من 008)
insert into auth.users (email) values ('x@gmail.com');
select testh.assert_eq('non-breadfast account can sign up but is inactive',
  (select role::text || is_active::text from public.profiles where email = 'x@gmail.com'), 'viewerfalse');

-- الـ Root محمي
select testh.expect_err($$update public.profiles set is_active = false where is_root$$, '%الأساسي%');
select testh.expect_err($$update public.profiles set role = 'viewer' where is_root$$, '%الأساسي%');
select testh.expect_err($$delete from public.profiles where is_root$$, '%الأساسي%');
select testh.expect_err($$delete from auth.users where email = 'mohamed.mahmoudsalah@breadfast.com'$$, '%الأساسي%');

-- مستخدم غير فعّال مش بيشوف حاجة
select testh.login('ali@breadfast.com');
select testh.assert_eq('inactive user sees no kitchens', (select count(*) from public.kitchens), 0::bigint);
select testh.assert_eq('inactive user sees no products', (select count(*) from public.products), 0::bigint);
select testh.expect_err($$select public.set_user_access(gen_random_uuid(), 'admin', true, '{}', '{}')$$, '%Admin أو الـ Manager%');
select testh.logout();

-- الـ Admin يدّي صلاحيات
select testh.login('mohamed.mahmoudsalah@breadfast.com');
select public.set_user_access(
  (select user_id from public.profiles where email = 'ali@breadfast.com'), 'kitchen_user', true,
  array[(select id from public.kitchens where code = 'PLUS_MALL')],
  array['import_export', 'opening_balance', 'purchases', 'waste', 'warehouse_transactions', 'stock_adjustments', 'access_control']);
select testh.assert_eq('access_control never assigned to non-admin',
  (select count(*) from public.user_pages where page_key = 'access_control'), 0::bigint);
select testh.expect_err(
  $$select public.set_user_access((select user_id from public.profiles where is_root), 'viewer', false, '{}', '{}')$$,
  '%الأساسي%');

-- دعوة مسبقة: بتتطبق عند أول دخول
select public.invite_user('Sara@breadfast.com', 'manager', true,
  array[(select id from public.kitchens where code = 'MAADI')], array['purchases', 'audit_log']);
select testh.expect_err($$select public.invite_user('not-an-email','viewer',true,'{}','{}')$$, '%الإيميل%');
select testh.logout();
insert into auth.users (email) values ('sara@breadfast.com');
select testh.assert_eq('invite applied on first login',
  (select p.role::text || p.is_active::text || (select count(*) from public.user_kitchens k where k.user_id = p.user_id)::text
          || (select count(*) from public.user_pages u where u.user_id = p.user_id)::text
     from public.profiles p where p.email = 'sara@breadfast.com'), 'managertrue12');
select testh.assert_eq('invite consumed', (select count(*) from public.access_invites), 0::bigint);

-- ===================== 2) Data Product import =====================
select testh.login('ali@breadfast.com');
select testh.expect_err($$select public.import_start('products', null, 'p.xlsx', 1)$$, '%Admin والـ Manager%');
select testh.logout();

select testh.login('mohamed.mahmoudsalah@breadfast.com');
-- ملف فيه Syt Code مكرر + صف ناقص => ولا صف يتحفظ
select testh.stage('products', null, '[
  {"generic_code":"G1","syt_code":"S1","name":"Flour","category":"Dry","uom_name":"Unit","cost_per_uom":"10","factor":"5"},
  {"generic_code":"G1","syt_code":"S2","name":"Flour 1kg","category":"Dry","uom_name":"Kg","cost_per_uom":"11","factor":"1"},
  {"generic_code":"G3","syt_code":"S1","name":"Dup","cost_per_uom":"1"},
  {"syt_code":"S4","name":"Bad cost","cost_per_uom":"abc"},
  {"syt_code":"","name":"No syt"}
]'::jsonb) as bad_batch \gset
select testh.assert_eq('bad products file -> failed', (select status from public.import_batches where id = :'bad_batch'), 'failed');
select testh.assert_eq('bad products file -> 3 errors', (select error_count from public.import_batches where id = :'bad_batch'), 3);
select testh.expect_err(format($$select public.import_commit(%L)$$, :'bad_batch'), '%Validate%');
select testh.assert_eq('nothing saved from bad file', (select count(*) from public.products), 0::bigint);

select testh.stage('products', null, '[
  {"generic_code":"G1","syt_code":"S1","name":"Flour 5kg bag","category":"Dry","uom_name":"Unit","cost_per_uom":"10","factor":"5"},
  {"generic_code":"G1","syt_code":"S2","name":"Flour 1kg","category":"Dry","uom_name":"Kg","cost_per_uom":"11","factor":"1"},
  {"generic_code":"G3","syt_code":"S3","name":"Sugar","category":"Dry","uom_name":"Kg","cost_per_uom":"20","factor":""},
  {"syt_code":"S9","name":"Salt","cost_per_uom":"5"}
]'::jsonb) as good_batch \gset
select testh.assert_eq('good products file validated', (select status from public.import_batches where id = :'good_batch'), 'validated');
select public.import_commit(:'good_batch'::uuid) as res \gset
select testh.assert_eq('4 products inserted', (select count(*) from public.products), 4::bigint);
select testh.assert_eq('generic code can repeat', (select count(*) from public.products where generic_code = 'G1'), 2::bigint);
select testh.expect_err(format($$select public.import_commit(%L)$$, :'good_batch'), '%اتحفظ قبل كده%');

-- تحديث: القيم الفاضية بتحافظ على القيمة القديمة
select testh.stage('products', null, '[{"syt_code":"S1","name":"Flour 5kg bag v2","cost_per_uom":"12"}]'::jsonb) as upd \gset
select public.import_commit(:'upd'::uuid) as res \gset
select testh.assert_eq('update keeps UOM when blank',
  (select uom_factor::text || '/' || cost::text || '/' || cost_per_uom::text || '/' || name from public.products where syt_code = 'S1'), '5.000000/60.0000/12.0000/Flour 5kg bag v2');
select testh.logout();

-- ===================== 3) Opening (UOM + all-or-nothing + per-kitchen) =====================
select id as k_plus from public.kitchens where code = 'PLUS_MALL' \gset
select id as k_maadi from public.kitchens where code = 'MAADI' \gset

select testh.login('ali@breadfast.com');
select testh.expect_err(format($$select public.import_start('opening', %L, 'o.xlsx', 1)$$, :'k_maadi'), '%مش مسموحلك%');
select testh.expect_err(format($$select public.import_start('opening', null, 'o.xlsx', 1)$$), '%اختار المطبخ%');

-- G1 ملتبس (منتجين) + كود مش موجود + كمية سالبة => ولا صف
select testh.stage('opening', :'k_plus', '[
  {"date":"2026-10-01","code":"S1","qty":"4"},
  {"date":"2026-10-01","code":"G1","qty":"1"},
  {"date":"2026-10-01","code":"NOPE","qty":"1"},
  {"date":"2026-10-01","code":"S2","qty":"-3"},
  {"date":"01/10/2026","code":"S3","qty":"1"}
]'::jsonb) as ob_bad \gset
select testh.assert_eq('opening bad: 4 errors', (select error_count from public.import_batches where id = :'ob_bad'), 4);
select testh.assert_eq('ambiguous generic code flagged',
  (select count(*) from public.import_errors where batch_id = :'ob_bad' and row_no = 2 and reason like '%بيطابق 2 منتجات%'), 1::bigint);
select testh.assert_eq('errors carry row_no + raw',
  (select raw ->> 'code' from public.import_errors where batch_id = :'ob_bad' and row_no = 3), 'NOPE');
select testh.assert_eq('opening bad: no documents', (select count(*) from public.documents), 0::bigint);
select testh.assert_eq('opening bad: no ledger', (select count(*) from public.stock_ledger), 0::bigint);

-- مكرر + تواريخ مختلفة
select testh.stage('opening', :'k_plus', '[
  {"date":"2026-10-01","code":"S1","qty":"4"},
  {"date":"2026-10-01","code":"S1","qty":"1"},
  {"date":"2026-10-02","code":"S2","qty":"1"}
]'::jsonb) as ob_bad2 \gset
select testh.assert_eq('opening: dup product + 2 dates -> 2 errors', (select error_count from public.import_batches where id = :'ob_bad2'), 2);

-- سليم: S1 uom=5 => 4 قطع = 20 كيلو، Qty Base مباشرة، S3 (uom=1)
select testh.stage('opening', :'k_plus', '[
  {"date":"2026-10-01","code":"S1","qty":"4"},
  {"date":"2026-10-01","code":"G3","qty_base":"7.5"},
  {"date":"2026-10-01","code":"S2","qty_pieces":"3"}
]'::jsonb) as ob_ok \gset
select public.import_commit(:'ob_ok'::uuid) as res \gset
select testh.assert_eq('S1: 4 pieces x UOM 5 = 20 base',
  (select qty_base from public.stock_balances b join public.products p on p.id = b.product_id where p.syt_code = 'S1'), 20::numeric);
select testh.assert_eq('S3 qty_base 7.5',
  (select qty_base from public.stock_balances b join public.products p on p.id = b.product_id where p.syt_code = 'S3'), 7.5::numeric);
select testh.assert_eq('line keeps pieces + base + factor snapshot',
  (select qty_pieces::text || '/' || qty_base::text || '/' || uom_factor_snapshot::text
     from public.document_lines l join public.products p on p.id = l.product_id where p.syt_code = 'S1'), '4.0000/20.0000/5.000000');
select testh.assert_eq('ledger rows written', (select count(*) from public.stock_ledger), 3::bigint);
select testh.assert_eq('document posted', (select status from public.documents where doc_type = 'OPENING'), 'POSTED');

-- رصيد افتتاحي واحد
select testh.stage('opening', :'k_plus', '[{"date":"2026-10-01","code":"S9","qty":"1"}]'::jsonb) as ob_again \gset
select testh.assert_eq('second opening rejected', (select error_count from public.import_batches where id = :'ob_again'), 1);
select testh.assert_eq('second opening reason',
  (select count(*) from public.import_errors where batch_id = :'ob_again' and row_no = 0 and reason like '%Reverse%'), 1::bigint);

-- عزل المطابخ بالـ RLS
select testh.assert_eq('ali sees only his kitchen', (select count(*) from public.kitchens), 1::bigint);
select testh.assert_eq('ali sees his documents', (select count(*) from public.documents), 1::bigint);
select testh.logout();

select testh.login('sara@breadfast.com');
select testh.assert_eq('sara (Maadi) sees no Plus Mall docs', (select count(*) from public.documents), 0::bigint);
select testh.assert_eq('sara sees no Plus Mall balances', (select count(*) from public.stock_balances), 0::bigint);
select testh.assert_eq('sara sees no Plus Mall ledger', (select count(*) from public.stock_ledger), 0::bigint);
select testh.logout();

-- ===================== 4) No negative stock =====================
select testh.login('ali@breadfast.com');
-- S2 رصيده 3 قطع x 1 = 3 | waste 2 ثم 2 في يوم تاني => تجاوز
select testh.stage('waste', :'k_plus', '[
  {"date":"2026-10-02","code":"S2","qty":"2","reason":"Damage"},
  {"date":"2026-10-03","code":"S2","qty":"2","reason":"Damage"}
]'::jsonb) as w_bad \gset
select testh.assert_eq('waste exceeding balance rejected', (select error_count from public.import_batches where id = :'w_bad'), 1);
select testh.assert_eq('waste error points at row 2',
  (select row_no from public.import_errors where batch_id = :'w_bad'), 2);
select testh.assert_eq('waste error text', (select count(*) from public.import_errors where batch_id = :'w_bad' and reason like '%رصيد غير كافٍ%'), 1::bigint);

select testh.stage('waste', :'k_plus', '[{"date":"2026-10-02","code":"S2","qty":"2","reason":"Damage"}]'::jsonb) as w_ok \gset
select public.import_commit(:'w_ok'::uuid) as res \gset
select testh.assert_eq('waste deducted from balance',
  (select qty_base from public.stock_balances b join public.products p on p.id = b.product_id where p.syt_code = 'S2'), 1::numeric);

-- حماية الـ DB نفسها: حتى لو حد عدّى الـ validate
select testh.logout();
select testh.expect_err(
  format($$insert into public.stock_ledger (document_id, line_id, kitchen_id, product_id, movement_type, qty_base, unit_cost, posting_date)
           select d.id, l.id, d.kitchen_id, l.product_id, 'WASTE', -100, 0, d.doc_date
             from public.documents d join public.document_lines l on l.document_id = d.id limit 1$$),
  '%violates check constraint%');

-- تسوية: Reason + إشارة
select testh.login('ali@breadfast.com');
select testh.stage('adjustments', :'k_plus', '[
  {"date":"2026-10-04","code":"S2","qty":"-1","reason":"Missing"},
  {"date":"2026-10-04","code":"S2","qty":"1","reason":"Missing"},
  {"date":"2026-10-04","code":"S2","qty":"1"},
  {"date":"2026-10-04","code":"S2","qty":"-1","reason":"Overage"},
  {"date":"2026-10-04","code":"S2","qty":"1","reason":"Whatever"}
]'::jsonb) as adj_bad \gset
select testh.assert_eq('adjustment rules: 4 errors', (select error_count from public.import_batches where id = :'adj_bad'), 4);
select testh.stage('adjustments', :'k_plus', '[
  {"date":"2026-10-04","code":"S2","qty":"2","reason":"Overage"},
  {"date":"2026-10-04","code":"S3","qty":"-0.5","reason":"count correction"}
]'::jsonb) as adj_ok \gset
select public.import_commit(:'adj_ok'::uuid) as res \gset
select testh.assert_eq('adjustments applied', (select string_agg(p.syt_code || '=' || b.qty_base::text, ',' order by p.syt_code)
  from public.stock_balances b join public.products p on p.id = b.product_id where p.syt_code in ('S2','S3')), 'S2=3.0000,S3=7.0000');

-- ===================== 5) تجميد التكلفة =====================
select testh.logout();
select testh.login('mohamed.mahmoudsalah@breadfast.com');
select testh.stage('products', null, '[{"syt_code":"S1","name":"Flour 5kg bag v2","cost_per_uom":"99"}]'::jsonb) as c \gset
select public.import_commit(:'c'::uuid) as res \gset
select testh.assert_eq('old ledger keeps frozen cost',
  (select unit_cost from public.stock_ledger l join public.products p on p.id = l.product_id
    where p.syt_code = 'S1' and l.movement_type = 'OPENING'), 12::numeric);
select testh.logout();

-- ===================== 6) Ledger append-only / no hard delete =====================
select testh.expect_err($$update public.stock_ledger set qty_base = 1$$, '%append-only%');
select testh.expect_err($$delete from public.stock_ledger$$, '%append-only%');
select testh.expect_err($$truncate public.stock_ledger$$, '%append-only%');
select testh.expect_err($$delete from public.documents$$, '%Reverse%');
select testh.expect_err($$update public.audit_log set action = 'x'$$, '%append-only%');

-- المستخدم العادي مفيش كتابة مباشرة
select testh.login('ali@breadfast.com');
select testh.expect_err($$insert into public.stock_ledger (document_id, line_id, kitchen_id, product_id, movement_type, qty_base, unit_cost, posting_date)
  values (gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), 'PURCHASE', 1, 0, now())$$, '%permission denied%');
select testh.expect_err($$update public.products set cost = 0$$, '%permission denied%');
select testh.expect_err($$select public._post_document(gen_random_uuid())$$, '%permission denied%');
select testh.expect_err($$select public.import_commit(gen_random_uuid())$$, '%مش موجود%');
select testh.logout();

-- ===================== 7) Period lock =====================
select testh.login('ali@breadfast.com');
select testh.expect_err(format($$select public.close_period(%L, '2026-10-01', '2026-10-31')$$, :'k_plus'), '%Admin أو الـ Manager%');
select testh.logout();
select testh.login('mohamed.mahmoudsalah@breadfast.com');
select public.close_period(:'k_plus'::uuid, '2026-10-01', '2026-10-31') as period_id \gset
select testh.expect_err(format($$select public.close_period(%L, '2026-10-15', '2026-11-15')$$, :'k_plus'), '%conflicting key%');
select testh.logout();

select testh.login('ali@breadfast.com');
select testh.stage('purchases', :'k_plus', '[{"date":"2026-10-10","code":"S3","qty":"1"}]'::jsonb) as p_locked \gset
select testh.assert_eq('non-admin blocked in closed period',
  (select count(*) from public.import_errors where batch_id = :'p_locked' and reason like '%للـ Admin بس%'), 1::bigint);
select testh.stage('purchases', :'k_plus', '[{"date":"2026-11-02","code":"S3","qty":"1"}]'::jsonb) as p_open \gset
select testh.assert_eq('open period ok', (select status from public.import_batches where id = :'p_open'), 'validated');
select testh.logout();

select testh.login('mohamed.mahmoudsalah@breadfast.com');
select testh.stage('purchases', :'k_plus', '[{"date":"2026-10-10","code":"S3","qty":"1"}]'::jsonb) as a_nor \gset
select testh.assert_eq('admin needs override reason', (select count(*) from public.import_errors where batch_id = :'a_nor' and reason like '%override%'), 1::bigint);
select testh.stage('purchases', :'k_plus', '[{"date":"2026-10-10","code":"S3","qty":"1"}]'::jsonb, 'PIECE', 'تصحيح فاتورة') as a_ovr \gset
select public.import_commit(:'a_ovr'::uuid) as res \gset
select testh.assert_eq('override reason recorded', (select override_reason from public.documents where import_batch_id = :'a_ovr'), 'تصحيح فاتورة');
select testh.logout();

-- ===================== 8) Reverse =====================
select testh.login('ali@breadfast.com');
select testh.expect_err(format($$select public.reverse_document(%L, 'x')$$, (select id from public.documents where doc_type = 'OPENING' and reverses_document_id is null)), '%Manager%');
select testh.logout();

-- ويست على S1 بيخلي رصيده أقل من الافتتاحي => الـ Reverse للافتتاحي لازم يترفض
select testh.login('ali@breadfast.com');
select testh.stage('waste', :'k_plus', '[{"date":"2026-11-03","code":"S1","qty_base":"15","reason":"Damage"}]'::jsonb) as w_s1 \gset
select public.import_commit(:'w_s1'::uuid) as res \gset
select testh.logout();

select testh.login('mohamed.mahmoudsalah@breadfast.com');
select id as opening_doc from public.documents where doc_type = 'OPENING' and reverses_document_id is null \gset
-- الرصيد الحالي مش بيسمح (S1 اتخصم منه ويست) => مرفوض
select testh.expect_err(format($$select public.reverse_document(%L, 'غلط')$$, :'opening_doc'), '%مش بيسمح بالـ Reverse%');

-- Reverse للـ Purchase اللي دخل بـ override
select id as pur_doc from public.documents where doc_type = 'PURCHASE' \gset
select public.reverse_document(:'pur_doc'::uuid, 'مكرر') as rev_id \gset
select testh.assert_eq('reverse: original marked REVERSED', (select status from public.documents where id = :'pur_doc'), 'REVERSED');
select testh.assert_eq('reverse: balance back',
  (select qty_base from public.stock_balances b join public.products p on p.id = b.product_id where p.syt_code = 'S3'), 7::numeric);
select testh.assert_eq('reverse: ledger nets to zero for that doc pair',
  (select sum(qty_base) from public.stock_ledger where document_id in (:'pur_doc'::uuid, :'rev_id'::uuid)), 0::numeric);
select testh.assert_eq('reverse: movement_type kept + flagged', (select string_agg(movement_type || is_reversal::text, ',' order by id)
  from public.stock_ledger where document_id in (:'pur_doc'::uuid, :'rev_id'::uuid)), 'PURCHASEfalse,PURCHASEtrue');
select testh.expect_err(format($$select public.reverse_document(%L, 'تاني')$$, :'pur_doc'), '%مش قابل للـ Reverse%');
select testh.expect_err(format($$select public.reverse_document(%L, 'تاني')$$, :'rev_id'), '%مش قابل للـ Reverse%');

-- Adjustment ترجّع الرصيد، وبعدها Reverse للافتتاحي بيشتغل لما نعكس الحركات اللي بعده
select testh.logout();

-- ===================== 9) Audit =====================
select testh.assert_eq('audit: products inserts logged', (select count(*) > 0 from public.audit_log where table_name = 'products' and action = 'INSERT'), true);
select testh.assert_eq('audit: documents logged with kitchen', (select count(*) > 0 from public.audit_log where table_name = 'documents' and kitchen_id is not null), true);
select testh.assert_eq('audit: access changes logged with user email',
  (select count(*) > 0 from public.audit_log where table_name = 'user_kitchens' and user_email = 'mohamed.mahmoudsalah@breadfast.com'), true);
select testh.login('sara@breadfast.com');
select testh.assert_eq('manager sees audit only for own kitchen',
  (select count(*) from public.audit_log where kitchen_id is distinct from (select id from public.kitchens where code = 'MAADI')), 0::bigint);
select testh.logout();
select testh.login('ali@breadfast.com');
select testh.assert_eq('kitchen user sees no audit log', (select count(*) from public.audit_log), 0::bigint);
select testh.logout();


-- ===================== 10) Data Product من الموقع (Admin + Manager) =====================
select testh.login('mohamed.mahmoudsalah@breadfast.com');
select public.set_user_access((select user_id from public.profiles where email = 'sara@breadfast.com'), 'manager', true,
  array[(select id from public.kitchens where code = 'MAADI')], array['purchases', 'audit_log', 'data_product', 'waste']);
select testh.logout();
insert into auth.users (email) values ('viewer1@breadfast.com');
select testh.login('mohamed.mahmoudsalah@breadfast.com');
select public.set_user_access((select user_id from public.profiles where email = 'viewer1@breadfast.com'), 'viewer', true,
  array[(select id from public.kitchens where code = 'MAADI')], array['waste', 'data_product']);
select testh.logout();

select testh.login('sara@breadfast.com');
select public.save_product(null, '{"syt_code":"S20","generic_code":"G20","name":"Rice 3kg","uom_name":"Unit","category":"Dry","factor":"3","cost":"30"}'::jsonb) as p20 \gset
select testh.assert_eq('manager adds product; cost per UOM derived from cost/factor',
  (select cost::text || '/' || cost_per_uom::text || '/' || uom_factor::text from public.products where id = :'p20'), '30.0000/10.0000/3.000000');
select testh.expect_err($$select public.save_product(null, '{"syt_code":"S20","name":"dup"}'::jsonb)$$, '%موجود بالفعل%');
select testh.expect_err($$select public.save_product(null, '{"name":"no syt"}'::jsonb)$$, '%Syt Code مطلوب%');
select testh.expect_err($$select public.save_product(null, '{"syt_code":"S21","name":"x","factor":"0"}'::jsonb)$$, '%أكبر من صفر%');
select public.save_product(:'p20'::uuid, '{"name":"Rice 3kg v2","category":""}'::jsonb) as _ \gset
select testh.assert_eq('edit keeps factor/costs, blank text clears',
  (select name || '/' || coalesce(category, 'NULL') || '/' || uom_factor::text || '/' || cost_per_uom::text from public.products where id = :'p20'), 'Rice 3kg v2/NULL/3.000000/10.0000');
select testh.expect_err(format($$select public.delete_product(%L)$$, :'p20'), '%للـ Admin بس%');
select testh.expect_err(format($$select public.set_product_active(%L, false)$$, :'p20'), '%للـ Admin بس%');

-- مود الـ Import: insert فقط / update فقط
select testh.stage('products', null, '[{"syt_code":"S2","name":"again"},{"syt_code":"S50","name":"new one"}]'::jsonb, 'BASE', null, 'insert') as m_ins \gset
select testh.assert_eq('insert-only rejects existing Syt', (select count(*) from public.import_errors where batch_id = :'m_ins' and reason like '%موجود بالفعل%'), 1::bigint);
select testh.stage('products', null, '[{"syt_code":"S2","cost_per_uom":"13"},{"syt_code":"NOPE","cost_per_uom":"1"}]'::jsonb, 'BASE', null, 'update') as m_upd_bad \gset
select testh.assert_eq('update-only rejects unknown Syt', (select count(*) from public.import_errors where batch_id = :'m_upd_bad' and reason like '%مش موجود%'), 1::bigint);
select testh.stage('products', null, '[{"syt_code":"S2","cost_per_uom":"13"}]'::jsonb, 'BASE', null, 'update') as m_upd \gset
select public.import_commit(:'m_upd'::uuid) as res \gset
select testh.assert_eq('update-only keeps name/factor, cost follows cost_per_uom',
  (select name || '/' || uom_factor::text || '/' || cost::text || '/' || cost_per_uom::text from public.products where syt_code = 'S2'), 'Flour 1kg/1.000000/13.0000/13.0000');
select testh.stage('products', null, '[{"syt_code":"S60","name":"Via file","factor":"4","cost":"40"}]'::jsonb) as m_up \gset
select public.import_commit(:'m_up'::uuid) as res \gset
select testh.assert_eq('manager imports products from file',
  (select cost_per_uom::text from public.products where syt_code = 'S60'), '10.0000');
select testh.logout();

select testh.login('ali@breadfast.com');
select testh.expect_err($$select public.save_product(null, '{"syt_code":"S70","name":"x"}'::jsonb)$$, '%Admin والـ Manager%');
select testh.logout();

-- Cost mismatch flag + الحذف للـ Admin وللمنتجات غير المستخدمة بس
select testh.login('mohamed.mahmoudsalah@breadfast.com');
select public.save_product(null, '{"syt_code":"S80","name":"Bad costs","factor":"5","cost":"100","cost_per_uom":"10"}'::jsonb) as p80 \gset
select testh.assert_eq('cost mismatch flagged', (select cost_mismatch from public.products where id = :'p80'), true);
select testh.assert_eq('consistent costs not flagged', (select cost_mismatch from public.products where syt_code = 'S1'), false);
select testh.expect_err(format($$select public.delete_product(%L)$$, (select id from public.products where syt_code = 'S1')), '%مستخدم في حركات%');
select public.delete_product(:'p80'::uuid);
select testh.assert_eq('admin deletes unused product', (select count(*) from public.products where syt_code = 'S80'), 0::bigint);
select public.set_product_active((select id from public.products where syt_code = 'S60'), false);
select testh.assert_eq('inactive product flagged', (select is_active from public.products where syt_code = 'S60'), false);
select testh.logout();

-- ===================== 11) قايمة الأسباب (Waste + Adjustments) =====================
select testh.login('viewer1@breadfast.com');
select testh.expect_err($$select public.add_reason('Spilled', 'DECREASE')$$, '%مش مسموحلك%');
select testh.assert_eq('everyone active can read reasons', (select count(*) from public.reasons), 6::bigint);
select testh.logout();

select testh.login('ali@breadfast.com');
select public.add_reason('  Spilled ', 'DECREASE') as _ \gset
select testh.expect_err($$select public.add_reason('spilled', 'ANY')$$, '%موجود بالفعل%');
select testh.expect_err($$select public.add_reason('x', 'ANY')$$, '%من 2 لـ 60%');
select testh.expect_err($$select public.add_reason('Okay', 'SIDEWAYS')$$, '%اتجاه%');
select testh.expect_err($$select public.set_reason_active(gen_random_uuid(), false)$$, '%للـ Admin بس%');
select public.import_start('waste', :'k_plus', 'x.xlsx', 1) as b_def \gset
select testh.assert_eq('qty_mode defaults to BASE', (select qty_mode from public.import_batches where id = :'b_def'), 'BASE');
select testh.assert_eq('kitchen user added a reason', (select count(*) from public.reasons where name = 'Spilled'), 1::bigint);

-- S3 رصيده 7: Waste بسبب من القايمة
select testh.stage('waste', :'k_plus', '[
  {"date":"2026-11-04","code":"S3","qty":"1","reason":"spilled"},
  {"date":"2026-11-04","code":"S3","qty":"1","reason":"Merge"}
]'::jsonb, 'BASE') as wr_ok \gset
select testh.stage('waste', :'k_plus', '[{"date":"2026-11-04","code":"S3","qty":"1"}]'::jsonb, 'BASE') as wr_none \gset
select testh.assert_eq('waste without reason is rejected (reason required)', (select count(*) from public.import_errors where batch_id = :'wr_none' and reason like '%Reason مطلوب%'), 1::bigint);
select testh.assert_eq('waste with list reasons accepted', (select status from public.import_batches where id = :'wr_ok'), 'validated');
select public.import_commit(:'wr_ok'::uuid) as res \gset
select testh.assert_eq('waste lines keep reason names + ids',
  (select string_agg(coalesce(l.reason, 'none') || ':' || (l.reason_id is not null)::text, ',' order by l.line_no)
     from public.document_lines l join public.documents d on d.id = l.document_id where d.import_batch_id = :'wr_ok'),
  'Spilled:true,Merge:true');

select testh.stage('waste', :'k_plus', '[
  {"date":"2026-11-05","code":"S3","qty":"1","reason":"Overage"},
  {"date":"2026-11-05","code":"S3","qty":"1","reason":"Nope"}
]'::jsonb, 'BASE') as wr_bad \gset
select testh.assert_eq('waste: increase-only and unknown reasons rejected', (select error_count from public.import_batches where id = :'wr_bad'), 2);

-- Adjustment: اتجاه السبب بيحدد الإشارة، و Merge/ANY أي إشارة
select testh.stage('adjustments', :'k_plus', '[
  {"date":"2026-11-05","code":"S3","qty":"1","reason":"Spilled"},
  {"date":"2026-11-05","code":"S3","qty":"-1","reason":"Merge"},
  {"date":"2026-11-05","code":"S3","qty":"2","reason":"merge"}
]'::jsonb, 'BASE') as adj_dir \gset
select testh.assert_eq('adjustment: custom DECREASE reason rejects positive qty', (select error_count from public.import_batches where id = :'adj_dir'), 1);
select testh.logout();

select testh.login('mohamed.mahmoudsalah@breadfast.com');
select public.set_reason_active((select id from public.reasons where name = 'Merge'), false);
select testh.logout();
select testh.login('ali@breadfast.com');
select testh.stage('waste', :'k_plus', '[{"date":"2026-11-06","code":"S3","qty":"1","reason":"Merge"}]'::jsonb, 'BASE') as wr_inact \gset
select testh.assert_eq('deactivated reason no longer accepted', (select error_count from public.import_batches where id = :'wr_inact'), 1);
select testh.logout();
select testh.assert_eq('audit: reasons logged', (select count(*) > 0 from public.audit_log where table_name = 'reasons'), true);

\echo ALL SQL TESTS PASSED

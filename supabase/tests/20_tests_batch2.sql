-- اختبارات الدفعة 2 (بتشتغل بعد 10_tests.sql على نفس الـ DB)
\set ON_ERROR_STOP on
\set QUIET on

create function testh.line(p_syt text, p_qty text, p_mode text default 'BASE', p_reason text default null, p_dir text default null)
returns jsonb language sql as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'product_id', (select id from public.products where syt_code = p_syt),
    'qty', p_qty, 'mode', p_mode,
    'reason_id', (select id from public.reasons where name = p_reason),
    'direction', p_dir))
$$;

-- رصيد (بيتنادى كـ superuser)
create function testh.bal(p_kitchen text, p_loc text, p_syt text) returns numeric language sql as $$
  select coalesce((select b.qty_base from public.stock_balances b
    join public.kitchens k on k.id = b.kitchen_id join public.products p on p.id = b.product_id
   where k.code = p_kitchen and b.location = p_loc and p.syt_code = p_syt), 0)
$$;

select id as k_plus from public.kitchens where code = 'PLUS_MALL' \gset
select id as k_maadi from public.kitchens where code = 'MAADI' \gset

-- ===== صلاحيات + منتجات الاختبار =====
select testh.login('mohamed.mahmoudsalah@breadfast.com');
select public.set_user_access((select user_id from public.profiles where email = 'ali@breadfast.com'), 'kitchen_user', true,
  array[:'k_plus'::uuid], (select array_agg(key) from public.pages where key <> 'access_control'));
select public.set_user_access((select user_id from public.profiles where email = 'sara@breadfast.com'), 'manager', true,
  array[:'k_maadi'::uuid], (select array_agg(key) from public.pages where key <> 'access_control'));
select public.save_product(null, '{"syt_code":"T1","name":"Test 5kg","factor":"5","cost_per_uom":"10"}'::jsonb) as _ \gset
select public.save_product(null, '{"syt_code":"T2","name":"Test 1kg","factor":"1","cost_per_uom":"4"}'::jsonb) as _ \gset
select public.save_product(null, '{"syt_code":"T3","name":"Test 2kg","factor":"2","cost_per_uom":"3"}'::jsonb) as _ \gset
select testh.logout();

-- ===================== 1) إدخال يدوي: Draft -> Post =====================
select testh.login('ali@breadfast.com');
select public.save_document(null, 'PURCHASE', :'k_plus', '2026-12-01', 'first', jsonb_build_array(
  testh.line('T1', '10', 'PIECE'), testh.line('T2', '100'))) as pur \gset
select testh.assert_eq('draft created with 2 lines', (select count(*) from public.document_lines where document_id = :'pur'), 2::bigint);
select testh.assert_eq('pieces -> base conversion (10 x 5)', (select qty_base from public.document_lines l join public.products p on p.id = l.product_id
  where l.document_id = :'pur' and p.syt_code = 'T1'), 50::numeric);
select testh.assert_eq('base -> pieces kept alongside', (select qty_pieces from public.document_lines l join public.products p on p.id = l.product_id
  where l.document_id = :'pur' and p.syt_code = 'T1'), 10::numeric);
select testh.assert_eq('draft has no ledger rows', (select count(*) from public.stock_ledger where document_id = :'pur'), 0::bigint);

-- تعديل الـ Draft (بيستبدل السطور)
select public.save_document(:'pur'::uuid, null, null, '2026-12-01', 'edited', jsonb_build_array(
  testh.line('T1', '10', 'PIECE'), testh.line('T2', '100'), testh.line('T3', '20'))) as _ \gset
select testh.assert_eq('draft edited to 3 lines', (select count(*) from public.document_lines where document_id = :'pur'), 3::bigint);

-- validation
select testh.expect_err(format($$select public.save_document(null, 'PURCHASE', %L, '2026-12-01', null, jsonb_build_array(testh.line('T1', '0')))$$, :'k_plus'), '%أكبر من صفر%');
select testh.expect_err(format($$select public.save_document(null, 'PURCHASE', %L, '2026-12-01', null, jsonb_build_array(testh.line('NOPE', '1')))$$, :'k_plus'), '%اختار المنتج%');
select testh.expect_err(format($$select public.save_document(null, 'PURCHASE', %L, '2026-12-01', null, '[]'::jsonb)$$, :'k_plus'), '%سطر واحد%');
select testh.expect_err(format($$select public.save_document(null, 'PURCHASE', %L, '2026-12-01', null, jsonb_build_array(testh.line('T1', 'abc')))$$, :'k_plus'), '%رقم%');
select testh.expect_err(format($$select public.save_document(null, 'PURCHASE', %L, '2026-12-01', null, jsonb_build_array(testh.line('S60', '1')))$$, :'k_plus'), '%غير Active%');
select testh.expect_err(format($$select public.save_document(null, 'PURCHASE', %L, '2026-12-01', null, jsonb_build_array(testh.line('T1', '1')))$$, :'k_maadi'), '%مش مسموحلك%');
select testh.expect_err(format($$select public.save_document(null, 'OPENING', %L, '2026-12-01', null, jsonb_build_array(testh.line('T1', '1')))$$, :'k_plus'), '%مش مدعوم%');

-- Post
select public.post_document(:'pur'::uuid);
select testh.logout();
select testh.assert_eq('posted', (select status from public.documents where id = :'pur'), 'POSTED');
select testh.assert_eq('balances T1/T2/T3', testh.bal('PLUS_MALL', 'WAREHOUSE', 'T1')::text || '/' || testh.bal('PLUS_MALL', 'WAREHOUSE', 'T2')::text
  || '/' || testh.bal('PLUS_MALL', 'WAREHOUSE', 'T3')::text, '50.0000/100.0000/20.0000');
select testh.assert_eq('cost frozen at post (cost per UOM)', (select unit_cost_snapshot from public.document_lines l join public.products p on p.id = l.product_id
  where l.document_id = :'pur' and p.syt_code = 'T1'), 10::numeric);

select testh.login('ali@breadfast.com');
select testh.expect_err(format($$select public.save_document(%L, null, null, '2026-12-02', null, jsonb_build_array(testh.line('T1', '1')))$$, :'pur'), '%مش Draft%');
select testh.expect_err(format($$select public.post_document(%L)$$, :'pur'), '%اتعمله Post%');
select testh.expect_err(format($$select public.delete_draft(%L)$$, :'pur'), '%Reverse%');

-- حذف Draft
select public.save_document(null, 'PURCHASE', :'k_plus', '2026-12-01', null, jsonb_build_array(testh.line('T1', '1'))) as dd \gset
select public.delete_draft(:'dd'::uuid);
select testh.assert_eq('draft deleted', (select count(*) from public.documents where id = :'dd'), 0::bigint);

-- فترة مقفولة (أكتوبر مقفول من اختبارات الدفعة 1)
select public.save_document(null, 'PURCHASE', :'k_plus', '2026-10-15', null, jsonb_build_array(testh.line('T2', '1'))) as locked \gset
select testh.expect_err(format($$select public.post_document(%L)$$, :'locked'), '%مقفولة%');
select public.delete_draft(:'locked'::uuid);

-- Warehouse Transaction: الرصيد المتاح (T2 = 100)
select public.save_document(null, 'WH_TXN', :'k_plus', '2026-12-02', null, jsonb_build_array(testh.line('T2', '150'))) as wht_big \gset
select testh.expect_err(format($$select public.post_document(%L)$$, :'wht_big'), '%رصيد غير كافٍ%');
select public.delete_draft(:'wht_big'::uuid);
select public.save_document(null, 'WH_TXN', :'k_plus', '2026-12-02', null, jsonb_build_array(testh.line('T2', '40'))) as wht \gset
select public.post_document(:'wht'::uuid);

-- Waste: السبب إجباري ولازم يكون نقص/Either
select testh.expect_err(format($$select public.save_document(null, 'WASTE', %L, '2026-12-03', null, jsonb_build_array(testh.line('T2', '10')))$$, :'k_plus'), '%اختار السبب%');
select testh.expect_err(format($$select public.save_document(null, 'WASTE', %L, '2026-12-03', null, jsonb_build_array(testh.line('T2', '10', 'BASE', 'Overage')))$$, :'k_plus'), '%للزيادة بس%');
select public.save_document(null, 'WASTE', :'k_plus', '2026-12-03', null, jsonb_build_array(testh.line('T2', '10', 'BASE', 'Damage'))) as wst \gset
select public.post_document(:'wst'::uuid);

-- Adjustments: الاتجاه حسب السبب
select testh.expect_err(format($$select public.save_document(null, 'ADJUSTMENT', %L, '2026-12-04', null, jsonb_build_array(testh.line('T2', '5', 'BASE', 'Missing', 'INCREASE')))$$, :'k_plus'), '%اتجاهه%');
select testh.expect_err(format($$select public.save_document(null, 'ADJUSTMENT', %L, '2026-12-04', null, jsonb_build_array(testh.line('T2', '5', 'BASE', 'Count Correction')))$$, :'k_plus'), '%زيادة ولا نقص%');
select public.save_document(null, 'ADJUSTMENT', :'k_plus', '2026-12-04', null, jsonb_build_array(
  testh.line('T2', '5', 'BASE', 'Missing'), testh.line('T2', '3', 'BASE', 'Count Correction', 'INCREASE'))) as adj \gset
select public.post_document(:'adj'::uuid);
select testh.logout();
select testh.assert_eq('T2 after wh txn(-40) waste(-10) adj(-5+3)', testh.bal('PLUS_MALL', 'WAREHOUSE', 'T2'), 48::numeric);
select testh.assert_eq('adjustment movement types', (select string_agg(movement_type, ',' order by movement_type) from public.stock_ledger where document_id = :'adj'), 'ADJ_MINUS,ADJ_PLUS');

-- ===================== 2) Transfers =====================
select testh.login('ali@breadfast.com');
select testh.expect_err(format($$select public.save_document(null, 'TRANSFER', %L, '2026-12-05', null, jsonb_build_array(testh.line('T1', '1')), %L)$$, :'k_plus', :'k_plus'), '%المطبخ المستلم%');
select testh.expect_err(format($$select public.save_document(null, 'TRANSFER', %L, '2026-12-05', null, jsonb_build_array(testh.line('T1', '1')))$$, :'k_plus'), '%المطبخ المستلم%');

select public.save_document(null, 'TRANSFER', :'k_plus', '2026-12-05', 'to maadi', jsonb_build_array(
  testh.line('T1', '30'), testh.line('T2', '20')), :'k_maadi') as tr1 \gset
select public.save_document(null, 'TRANSFER', :'k_plus', '2026-12-05', 'big', jsonb_build_array(testh.line('T1', '100')), :'k_maadi') as tr_big \gset
select testh.expect_err(format($$select public.post_document(%L)$$, :'tr_big'), '%رصيد غير كافٍ%');
select public.post_document(:'tr1'::uuid);
select testh.logout();

select testh.assert_eq('send: status PENDING_RECEIPT', (select status from public.documents where id = :'tr1'), 'PENDING_RECEIPT');
select testh.assert_eq('send: warehouse down, in-transit up (T1)', testh.bal('PLUS_MALL', 'WAREHOUSE', 'T1')::text || '/' || testh.bal('PLUS_MALL', 'IN_TRANSIT', 'T1')::text, '20.0000/30.0000');
select testh.assert_eq('send: receiver has nothing yet', testh.bal('MAADI', 'WAREHOUSE', 'T1'), 0::numeric);

-- المستلم يشوف التحويل المرسل (مش الـ Draft)
select testh.login('sara@breadfast.com');
select testh.assert_eq('receiver sees sent transfer', (select count(*) from public.documents where id = :'tr1'), 1::bigint);
select testh.assert_eq('receiver does not see sender draft', (select count(*) from public.documents where id = :'tr_big'), 0::bigint);
select id as ln1 from public.document_lines where document_id = :'tr1' and line_no = 1 \gset
select id as ln2 from public.document_lines where document_id = :'tr1' and line_no = 2 \gset
select testh.expect_err(format($$select public.receive_transfer(%L, jsonb_build_array(jsonb_build_object('line_id', %L, 'qty', '30')), '2026-12-06')$$, :'tr1', :'ln1'), '%لازم تحدد%');
select testh.expect_err(format($$select public.receive_transfer(%L, jsonb_build_array(jsonb_build_object('line_id', %L, 'qty', '31'), jsonb_build_object('line_id', %L, 'qty', '20')), '2026-12-06')$$,
  :'tr1', :'ln1', :'ln2'), '%أكبر من المرسل%');
select testh.logout();

select testh.login('ali@breadfast.com');
select testh.expect_err(format($$select public.receive_transfer(%L, jsonb_build_array(jsonb_build_object('line_id', %L, 'qty', '30'), jsonb_build_object('line_id', %L, 'qty', '20')), '2026-12-06')$$,
  :'tr1', :'ln1', :'ln2'), '%المستلم بس%');
select testh.expect_err(format($$select public.reverse_document(%L, 'x')$$, :'tr1'), '%Manager%');
select testh.logout();

-- استلام 22 من 30 (T1) و 20 كاملة (T2)
select testh.login('sara@breadfast.com');
select public.receive_transfer(:'tr1'::uuid, jsonb_build_array(
  jsonb_build_object('line_id', :'ln1', 'qty', '22'), jsonb_build_object('line_id', :'ln2', 'qty', '20')), '2026-12-06');
select testh.logout();
select testh.assert_eq('receive: RETURN_PENDING status', (select status from public.documents where id = :'tr1'), 'RETURN_PENDING');
select testh.assert_eq('receive: Maadi got actual qty', testh.bal('MAADI', 'WAREHOUSE', 'T1')::text || '/' || testh.bal('MAADI', 'WAREHOUSE', 'T2')::text, '22.0000/20.0000');
select testh.assert_eq('receive: in-transit cleared', testh.bal('PLUS_MALL', 'IN_TRANSIT', 'T1') + testh.bal('PLUS_MALL', 'IN_TRANSIT', 'T2'), 0::numeric);
select testh.assert_eq('receive: shortfall is return-pending on sender', testh.bal('PLUS_MALL', 'RETURN_PENDING', 'T1'), 8::numeric);
select testh.assert_eq('receive: sender warehouse unchanged until return', testh.bal('PLUS_MALL', 'WAREHOUSE', 'T1'), 20::numeric);

select testh.login('sara@breadfast.com');
select testh.expect_err(format($$select public.confirm_return(%L, jsonb_build_array(jsonb_build_object('line_id', %L, 'qty', '1')), '2026-12-07')$$, :'tr1', :'ln1'), '%المرسل بس%');
select testh.logout();

-- المرسل يأكد المرتجع على دفعات
select testh.login('ali@breadfast.com');
select testh.expect_err(format($$select public.confirm_return(%L, jsonb_build_array(jsonb_build_object('line_id', %L, 'qty', '9')), '2026-12-07')$$, :'tr1', :'ln1'), '%أكبر من المعلق%');
select public.confirm_return(:'tr1'::uuid, jsonb_build_array(jsonb_build_object('line_id', :'ln1', 'qty', '5')), '2026-12-07');
select testh.assert_eq('partial return: still pending', (select status from public.documents where id = :'tr1'), 'RETURN_PENDING');
select public.confirm_return(:'tr1'::uuid, jsonb_build_array(jsonb_build_object('line_id', :'ln1', 'qty', '3')), '2026-12-08');
select testh.assert_eq('full return: CLOSED_PARTIAL', (select status from public.documents where id = :'tr1'), 'CLOSED_PARTIAL');
select testh.expect_err(format($$select public.confirm_return(%L, jsonb_build_array(jsonb_build_object('line_id', %L, 'qty', '1')), '2026-12-09')$$, :'tr1', :'ln1'), '%مفيهوش مرتجع%');
select testh.logout();
select testh.assert_eq('return: sender warehouse restored', testh.bal('PLUS_MALL', 'WAREHOUSE', 'T1'), 28::numeric);
select testh.assert_eq('return: pending cleared', testh.bal('PLUS_MALL', 'RETURN_PENDING', 'T1'), 0::numeric);
select testh.assert_eq('T1 conserved across kitchens/locations (50)', (select sum(b.qty_base) from public.stock_balances b join public.products p on p.id = b.product_id where p.syt_code = 'T1'), 50::numeric);

-- تحويل كامل => COMPLETED
select testh.login('ali@breadfast.com');
select public.save_document(null, 'TRANSFER', :'k_plus', '2026-12-10', null, jsonb_build_array(testh.line('T3', '10')), :'k_maadi') as tr2 \gset
select public.post_document(:'tr2'::uuid);
select testh.logout();
select testh.login('sara@breadfast.com');
select id as ln_t2 from public.document_lines where document_id = :'tr2' and line_no = 1 \gset
select public.receive_transfer(:'tr2'::uuid, jsonb_build_array(jsonb_build_object('line_id', :'ln_t2', 'qty', '5', 'mode', 'PIECE')), '2026-12-11');
select testh.logout();
select testh.assert_eq('full receive (5 pieces x2 = 10): COMPLETED', (select status from public.documents where id = :'tr2'), 'COMPLETED');
select testh.assert_eq('T3 moved', testh.bal('PLUS_MALL', 'WAREHOUSE', 'T3')::text || '/' || testh.bal('MAADI', 'WAREHOUSE', 'T3')::text, '10.0000/10.0000');

-- إلغاء تحويل لسه ما اتستلمش (Manager/Admin) + مينفعش بعد الاستلام
select testh.login('ali@breadfast.com');
select public.save_document(null, 'TRANSFER', :'k_plus', '2026-12-12', null, jsonb_build_array(testh.line('T2', '5')), :'k_maadi') as tr3 \gset
select public.post_document(:'tr3'::uuid);
select testh.logout();
select testh.login('mohamed.mahmoudsalah@breadfast.com');
select public.reverse_document(:'tr3'::uuid, 'اتبعت بالغلط') as _ \gset
select testh.expect_err(format($$select public.reverse_document(%L, 'x')$$, :'tr2'), '%مش قابل للـ Reverse%');
select testh.logout();
select testh.assert_eq('cancel pending transfer: status + balances restored', (select status from public.documents where id = :'tr3')
  || '/' || testh.bal('PLUS_MALL', 'WAREHOUSE', 'T2')::text || '/' || testh.bal('PLUS_MALL', 'IN_TRANSIT', 'T2')::text, 'REVERSED/28.0000/0.0000');

-- ===================== 3) Closing / Stock Count =====================
select testh.login('ali@breadfast.com');
select testh.expect_err(format($$select public.save_document(null, 'CLOSING', %L, '2026-12-31', null, jsonb_build_array(testh.line('T1', '1'), testh.line('T1', '2')))$$, :'k_plus'), '%متكرر في الجرد%');
select public.save_document(null, 'CLOSING', :'k_plus', '2026-12-31', 'count', jsonb_build_array(testh.line('T1', '26'), testh.line('T3', '12'))) as cls \gset
select public.save_document(null, 'CLOSING', :'k_plus', '2026-12-31', 'dup', jsonb_build_array(testh.line('T1', '1'))) as cls2 \gset
select public.post_document(:'cls'::uuid);
select testh.expect_err(format($$select public.post_document(%L)$$, :'cls2'), '%duplicate key%');
select public.delete_draft(:'cls2'::uuid);
select testh.logout();
select testh.assert_eq('closing is a snapshot: no ledger rows', (select count(*) from public.stock_ledger where document_id = :'cls'), 0::bigint);
select testh.assert_eq('closing applies count variance to stock (book 28 -> count 26, book 10 -> count 12)',
  testh.bal('PLUS_MALL', 'WAREHOUSE', 'T1')::text || '/' || testh.bal('PLUS_MALL', 'WAREHOUSE', 'T3')::text, '26.0000/12.0000');
select testh.assert_eq('variance posted as Count Correction adjustment linked to the count',
  (select string_agg(p.syt_code || ':' || l.qty_base::text || ':' || l.reason, ',' order by p.syt_code)
     from public.documents d join public.document_lines l on l.document_id = d.id join public.products p on p.id = l.product_id
    where d.source_document_id = :'cls' and d.doc_type = 'ADJUSTMENT' and d.status = 'POSTED'),
  'T1:-2.0000:Count Correction,T3:2.0000:Count Correction');
select testh.assert_eq('uncounted product untouched (T2 stays at book)', testh.bal('PLUS_MALL', 'WAREHOUSE', 'T2'), 28::numeric);

-- Closing import (تاريخ واحد، الصفر مسموح، السالب لأ)
select testh.login('ali@breadfast.com');
select testh.stage('closing', :'k_plus', '[
  {"date":"2027-01-31","code":"T1","qty":"10"},
  {"date":"2027-01-31","code":"T2","qty":"0"},
  {"date":"2027-01-31","code":"T3","qty":"-1"},
  {"date":"2027-02-01","code":"T3","qty":"1"},
  {"date":"2027-01-31","code":"T1","qty":"1"}
]'::jsonb, 'BASE') as cl_bad \gset
select testh.assert_eq('closing import: negative, other date, duplicate => 3 errors', (select error_count from public.import_batches where id = :'cl_bad'), 3);
select testh.stage('closing', :'k_plus', '[{"date":"2027-01-31","code":"T1","qty":"10"},{"date":"2027-01-31","code":"T2","qty":"0"}]'::jsonb, 'BASE') as cl_ok \gset
select public.import_commit(:'cl_ok'::uuid) as _ \gset
select testh.logout();
select testh.assert_eq('closing import saved as POSTED snapshot with zero line',
  (select d.status || '/' || (select count(*) from public.document_lines l where l.document_id = d.id)::text || '/' || (select count(*) from public.stock_ledger sl where sl.document_id = d.id)::text
     from public.documents d where d.import_batch_id = :'cl_ok'), 'POSTED/2/0');

-- ===================== 4) Reports =====================
-- Warehouse Stock: الصيغة لازم تساوي رصيد الـ Ledger الفعلي
select testh.login('ali@breadfast.com');
select testh.assert_eq('warehouse stock formula = ledger balance (all products)',
  (select count(*) from public.report_warehouse_stock(:'k_plus', '2026-12-01', '2027-01-31') w
    where w.closing_book is distinct from (select coalesce(b.qty_base, 0) from public.stock_balances b
        where b.kitchen_id = :'k_plus' and b.location = 'WAREHOUSE' and b.product_id = w.product_id)), 0::bigint);
select testh.assert_eq('warehouse stock covers every product with a balance',
  (select count(*) from public.stock_balances b where b.kitchen_id = :'k_plus' and b.location = 'WAREHOUSE' and b.qty_base > 0
     and not exists (select 1 from public.report_warehouse_stock(:'k_plus', '2026-12-01', '2027-01-31') w where w.product_id = b.product_id)), 0::bigint);
select testh.assert_eq('T1 Plus Mall columns (count variance shows as adjustment, stock = counted 26)',
  (select concat_ws('/', opening::numeric(18,4), purchases::numeric(18,4), transfer_in::numeric(18,4), transfer_out::numeric(18,4), warehouse_txn::numeric(18,4), waste::numeric(18,4), adjustments::numeric(18,4), closing_book::numeric(18,4), in_transit::numeric(18,4), return_pending::numeric(18,4))
     from public.report_warehouse_stock(:'k_plus', '2026-12-01', '2026-12-31') where syt_code = 'T1'),
  '0.0000/50.0000/0.0000/22.0000/0.0000/0.0000/-2.0000/26.0000/0.0000/0.0000');
select testh.assert_eq('T2 Plus Mall columns (wh txn 40, waste 10, adj -2, transfer out 20)',
  (select concat_ws('/', purchases::numeric(18,4), transfer_out::numeric(18,4), warehouse_txn::numeric(18,4), waste::numeric(18,4), adjustments::numeric(18,4), closing_book::numeric(18,4))
     from public.report_warehouse_stock(:'k_plus', '2026-12-01', '2026-12-31') where syt_code = 'T2'),
  '100.0000/20.0000/40.0000/10.0000/-2.0000/28.0000');
select testh.assert_eq('opening carries earlier movements (period starts 12-06)',
  (select opening from public.report_warehouse_stock(:'k_plus', '2026-12-06', '2026-12-31') where syt_code = 'T1'), 20::numeric);
select testh.assert_eq('as-of date excludes later movements',
  (select closing_book from public.report_warehouse_stock(:'k_plus', '2026-12-01', '2026-12-05') where syt_code = 'T1'), 20::numeric);
select testh.assert_eq('in-transit visible mid-flow (to 12-05)',
  (select in_transit from public.report_warehouse_stock(:'k_plus', '2026-12-01', '2026-12-05') where syt_code = 'T1'), 30::numeric);
select testh.expect_err(format($$select * from public.report_warehouse_stock(%L, '2026-12-01', '2026-12-31')$$, :'k_maadi'), '%مش مسموحلك%');
select testh.expect_err(format($$select * from public.report_warehouse_stock(%L, '2026-12-31', '2026-12-01')$$, :'k_plus'), '%الفترة%');

-- Consumption = Opening + Purchases + TI - TO - Closing - Waste (الجرد 12-31)
select testh.assert_eq('consumption T1 (50 - 22 - closing 26 = 2)',
  (select concat_ws('/', opening::numeric(18,4), purchases::numeric(18,4), transfer_out::numeric(18,4), closing::numeric(18,4), consumption::numeric(18,4)) from public.report_consumption(:'k_plus', '2026-12-01', '2026-12-31') where syt_code = 'T1'),
  '0.0000/50.0000/22.0000/26.0000/2.0000');
select testh.assert_eq('consumption T3 (20 - 10 - closing 12 = -2)',
  (select consumption from public.report_consumption(:'k_plus', '2026-12-01', '2026-12-31') where syt_code = 'T3'), -2::numeric);
select testh.assert_eq('consumption T2 not in closing => closing 0 (100 - 20 - 10 waste = 70)',
  (select concat_ws('/', closing::numeric(18,4), consumption::numeric(18,4)) from public.report_consumption(:'k_plus', '2026-12-01', '2026-12-31') where syt_code = 'T2'), '0.0000/70.0000');
select testh.assert_eq('consumption flags closing doc date',
  (select has_closing::text || '/' || closing_date::text from public.report_consumption(:'k_plus', '2026-12-01', '2026-12-31') where syt_code = 'T1'), 'true/2026-12-31');
select testh.assert_eq('product that only appears in closing is not dropped',
  (select count(*) from public.report_consumption(:'k_plus', '2027-01-01', '2027-01-31') where syt_code = 'T2'), 1::bigint);
select testh.assert_eq('no closing in period => has_closing false, closing 0',
  (select has_closing::text || '/' || closing::numeric(18,4)::text from public.report_consumption(:'k_plus', '2026-12-01', '2026-12-20') where syt_code = 'T1'), 'false/0.0000');
select testh.logout();

select testh.login('sara@breadfast.com');
select testh.assert_eq('Maadi: transfer in is the confirmed qty only (22)',
  (select transfer_in from public.report_warehouse_stock(:'k_maadi', '2026-12-01', '2026-12-31') where syt_code = 'T1'), 22::numeric);
select testh.assert_eq('Maadi consumption without closing = all in-flow (22)',
  (select consumption from public.report_consumption(:'k_maadi', '2026-12-01', '2026-12-31') where syt_code = 'T1'), 22::numeric);
select testh.expect_err(format($$select * from public.report_consumption(%L, '2026-12-01', '2026-12-31')$$, :'k_plus'), '%مش مسموحلك%');
select testh.logout();

select testh.login('viewer1@breadfast.com');
select testh.expect_err(format($$select * from public.report_consumption(%L, '2026-12-01', '2026-12-31')$$, :'k_maadi'), '%مش مسموحلك%');
select testh.logout();

-- reverse closing => التقرير يتجاهله
select testh.login('mohamed.mahmoudsalah@breadfast.com');
select public.reverse_document(:'cls'::uuid, 'جرد غلط') as _ \gset
select testh.assert_eq('reversed closing is ignored by consumption',
  (select has_closing::text from public.report_consumption(:'k_plus', '2026-12-01', '2026-12-31') where syt_code = 'T1'), 'false');
select testh.assert_eq('reversing the count also reverses its variance adjustment',
  (select status from public.documents where source_document_id = :'cls' and doc_type = 'ADJUSTMENT' and reverses_document_id is null), 'REVERSED');
select testh.assert_eq('stock after reversal: T1 10+2, T3 12-2',
  testh.bal('PLUS_MALL', 'WAREHOUSE', 'T1')::text || '/' || testh.bal('PLUS_MALL', 'WAREHOUSE', 'T3')::text, '12.0000/10.0000');
select testh.logout();

\echo ALL BATCH-2 SQL TESTS PASSED

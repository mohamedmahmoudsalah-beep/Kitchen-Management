-- اختبارات 012: قفل بشهور كاملة، منع الإدخال في الفترة المقفولة، أرشفة ومسح الفترة بترحيل الرصيد، ترتيب الـ Product Card
\set ON_ERROR_STOP on
\set QUIET on

select id as k_maadi from public.kitchens where code = 'MAADI' \gset
insert into auth.users (email) values ('ku70@breadfast.com');
select testh.login('mohamed.mahmoudsalah@breadfast.com');
select public.set_user_access((select user_id from public.profiles where email = 'ku70@breadfast.com'), 'kitchen_user', true,
  array[:'k_maadi'::uuid], (select array_agg(key) from public.pages where key <> 'access_control'));
select public.save_product(null, '{"syt_code":"P70","name":"Batch6 a","factor":"2","cost_per_uom":"2"}'::jsonb) as _ \gset
select public.save_product(null, '{"syt_code":"P71","name":"Batch6 b","factor":"1","cost_per_uom":"1"}'::jsonb) as _ \gset
select testh.logout();

-- ===== بيانات: فبراير (هتتقفل وتتمسح) + أبريل (هتفضل) =====
select testh.login('ku70@breadfast.com');
select public.save_document(null, 'PURCHASE', :'k_maadi', '2026-02-10', null, jsonb_build_array(testh.line('P70', '50'), testh.line('P71', '20'))) as d1 \gset
select public.post_document(:'d1'::uuid);
select public.save_document(null, 'WASTE', :'k_maadi', '2026-02-20', null, jsonb_build_array(testh.line('P70', '5', 'BASE', 'Damage'))) as d2 \gset
select public.post_document(:'d2'::uuid);
select public.save_document(null, 'PURCHASE', :'k_maadi', '2026-03-10', 'draft in march', jsonb_build_array(testh.line('P71', '1'))) as dr \gset
select public.save_document(null, 'PURCHASE', :'k_maadi', '2026-04-05', null, jsonb_build_array(testh.line('P70', '10'))) as d3 \gset
select public.post_document(:'d3'::uuid);
select testh.logout();
select testh.assert_eq('balances before purge', testh.bal('MAADI', 'WAREHOUSE', 'P70')::text || '/' || testh.bal('MAADI', 'WAREHOUSE', 'P71')::text, '55.0000/20.0000');

-- ===== قفل بشهور كاملة =====
select testh.login('mohamed.mahmoudsalah@breadfast.com');
select testh.expect_err(format($$select public.close_period(%L, '2026-05-15', '2026-05-31')$$, :'k_maadi'), '%شهور كاملة%');
select testh.expect_err(format($$select public.close_period(%L, '2026-05-01', '2026-05-20')$$, :'k_maadi'), '%شهور كاملة%');
select public.close_period(:'k_maadi'::uuid, '2026-02-01', '2026-03-31') as _ \gset
select testh.logout();

-- ===== الفترة المقفولة: مفيش إضافة/تعديل/مسح لغير الـ Admin =====
select testh.login('ku70@breadfast.com');
select testh.expect_err(format($$select public.save_document(null, 'PURCHASE', %L, '2026-03-05', null, '[{"syt":"P71","qty":"1"}]'::jsonb)$$, :'k_maadi'), '%ارجع للـ Admin%');
select testh.expect_err(format($$select public.delete_draft(%L)$$, :'dr'), '%ارجع للـ Admin%');
select testh.expect_err(format($$select public.save_document(%L, null, null, '2026-04-06', null, '[{"syt":"P71","qty":"1"}]'::jsonb)$$, :'dr'), '%ارجع للـ Admin%');
select testh.logout();
insert into auth.users (email) values ('mg70@breadfast.com');
select testh.login('mohamed.mahmoudsalah@breadfast.com');
select public.set_user_access((select user_id from public.profiles where email = 'mg70@breadfast.com'), 'manager', true,
  array[:'k_maadi'::uuid], (select array_agg(key) from public.pages where key <> 'access_control'));
select testh.logout();
select testh.login('mg70@breadfast.com');
select testh.expect_err(format($$select public.reverse_document(%L, 'x')$$, :'d2'), '%ارجع للـ Admin%');
select testh.logout();
select testh.login('mohamed.mahmoudsalah@breadfast.com');
select public.delete_draft(:'dr'::uuid);
select testh.assert_eq('admin may still delete a draft in a closed period', (select count(*) from public.documents where id = :'dr'), 0::bigint);
select testh.logout();

-- ===== المسح: موانع =====
select testh.login('ku70@breadfast.com');
select testh.expect_err($$select public.purge_preview('2026-02-01', '2026-03-31')$$, '%Admin بس%');
select testh.logout();
select testh.login('mohamed.mahmoudsalah@breadfast.com');
select testh.assert_eq('April is not closed -> blocked',
  (select (public.purge_preview('2026-04-01', '2026-04-30') ->> 'ok')::text || '/' || (public.purge_preview('2026-04-01', '2026-04-30') -> 'blockers' ->> 0 like '%مش مقفولة%')::text), 'false/true');
select testh.expect_err($$select public.purge_range('2026-02-01', '2026-03-31', 'nope')$$, '%التأكيد غلط%');
select testh.expect_err($$select public.purge_range('2026-10-01', '2026-10-31', 'PURGE 2026-10 → 2026-10')$$, '%الشهر الحالي%');
select testh.expect_err($$select public.purge_range('2026-02-05', '2026-03-31', 'x')$$, '%شهور كاملة%');
select testh.assert_eq('Feb-Mar preview is ok', (public.purge_preview('2026-02-01', '2026-03-31') ->> 'ok'), 'true');

-- ===== المسح الفعلي =====
select string_agg(id::text, ',') as old_ids from public.documents where doc_date between '2026-02-01' and '2026-03-31' \gset
select (select string_agg(opening::text || '|' || closing_book::text, ',' order by syt_code) from public.report_warehouse_stock(:'k_maadi'::uuid, '2026-04-01', '2026-04-30') where syt_code in ('P70', 'P71')) as rep_before \gset
select public.purge_range('2026-02-01', '2026-03-31', 'PURGE 2026-02 → 2026-03') as res \gset
select testh.assert_eq('2 documents purged', (:'res'::jsonb ->> 'documents'), '2');
select testh.assert_eq('old documents are gone', (select count(*) from public.documents where id = any (string_to_array(:'old_ids', ',')::uuid[])), 0::bigint);
select testh.assert_eq('audit rows of purged docs are gone', (select count(*) from public.audit_log where table_name = 'documents' and row_id = any (string_to_array(:'old_ids', ','))), 0::bigint);
select testh.assert_eq('balances unchanged after purge', testh.bal('MAADI', 'WAREHOUSE', 'P70')::text || '/' || testh.bal('MAADI', 'WAREHOUSE', 'P71')::text, '55.0000/20.0000');
select testh.assert_eq('one carry-forward document with both lines',
  (select count(*) from public.document_lines l join public.documents d on d.id = l.document_id where d.doc_no like 'ARC-MAADI-%' and d.kitchen_id = :'k_maadi'), 2::bigint);
select testh.assert_eq('April report identical before/after purge',
  (select string_agg(opening::text || '|' || closing_book::text, ',' order by syt_code) from public.report_warehouse_stock(:'k_maadi'::uuid, '2026-04-01', '2026-04-30') where syt_code in ('P70', 'P71')), :'rep_before');
select testh.assert_eq('purge is logged', (select count(*) from public.purge_log where from_date = '2026-02-01' and to_date = '2026-03-31'), 1::bigint);
select testh.assert_eq('ledger still equals balances',
  (select count(*) from (select kitchen_id, location, product_id, sum(qty_base) q from public.stock_ledger group by 1, 2, 3) l
    join public.stock_balances b using (kitchen_id, location, product_id) where l.q <> b.qty_base), 0::bigint);
select testh.logout();

-- ===== بعد المسح: الفترة لسه مقفولة =====
select testh.login('ku70@breadfast.com');
select testh.expect_err(format($$select public.save_document(null, 'PURCHASE', %L, '2026-02-12', null, '[{"syt":"P71","qty":"1"}]'::jsonb)$$, :'k_maadi'), '%ارجع للـ Admin%');

-- ===== Product Card: ترتيب زمني بغض النظر عن وقت الإدخال =====
select public.save_document(null, 'PURCHASE', :'k_maadi', '2026-04-01', null, jsonb_build_array(testh.line('P70', '5'))) as d4 \gset
select public.post_document(:'d4'::uuid);
select testh.logout();
select testh.login('mohamed.mahmoudsalah@breadfast.com');
select testh.assert_eq('card is chronological with matching running balance',
  (select string_agg(movement_type || ':' || balance_after::numeric(18, 0)::text, ',') from public.product_card((select id from public.products where syt_code = 'P70'), :'k_maadi')),
  'OPENING:45,PURCHASE:50,PURCHASE:60');
select testh.logout();


-- ===== آخر حجم اتشترى لـ Generic Code =====
select testh.login('mohamed.mahmoudsalah@breadfast.com');
select public.save_product(null, '{"syt_code":"G80-S","generic_code":"G80","name":"Gen small","factor":"1","cost_per_uom":"1"}'::jsonb) as _ \gset
select public.save_product(null, '{"syt_code":"G80-L","generic_code":"G80","name":"Gen large","factor":"5","cost_per_uom":"1"}'::jsonb) as _ \gset
select public.save_document(null, 'PURCHASE', :'k_maadi', '2026-11-01', null, jsonb_build_array(testh.line('G80-S', '3'))) as g1 \gset
select public.post_document(:'g1'::uuid);
select public.save_document(null, 'PURCHASE', :'k_maadi', '2026-11-05', null, jsonb_build_array(testh.line('G80-L', '2'))) as g2 \gset
select public.post_document(:'g2'::uuid);
select testh.assert_eq('last purchased size wins', (select syt_code from public.last_purchased_syt(array['G80', 'NOPE'])), 'G80-L');
select testh.assert_eq('unknown generic returns nothing', (select count(*) from public.last_purchased_syt(array['NOPE'])), 0::bigint);
select public.reverse_document(:'g2'::uuid, 'oops') as _ \gset
select testh.assert_eq('reversed purchase is ignored', (select syt_code from public.last_purchased_syt(array['G80'])), 'G80-S');
select testh.logout();

\echo ALL BATCH-6 SQL TESTS PASSED

-- اختبارات 009: وجهات التحويل، قفل تعديل المشتريات، Opening بصفر، Product Card
\set ON_ERROR_STOP on
\set QUIET on

select id as k_plus from public.kitchens where code = 'PLUS_MALL' \gset
select id as k_maadi from public.kitchens where code = 'MAADI' \gset
select id as k_rehab from public.kitchens where code = 'REHAB' \gset

insert into auth.users (email) values ('ku50@breadfast.com');
insert into auth.users (email) values ('mg50@breadfast.com');
insert into auth.users (email) values ('vw50@breadfast.com');
select testh.login('mohamed.mahmoudsalah@breadfast.com');
select public.set_user_access((select user_id from public.profiles where email = 'ku50@breadfast.com'), 'kitchen_user', true,
  array[:'k_rehab'::uuid], (select array_agg(key) from public.pages where key <> 'access_control'));
select public.set_user_access((select user_id from public.profiles where email = 'mg50@breadfast.com'), 'manager', true,
  array[:'k_rehab'::uuid], (select array_agg(key) from public.pages where key <> 'access_control'));
select public.set_user_access((select user_id from public.profiles where email = 'vw50@breadfast.com'), 'viewer', true,
  array[:'k_rehab'::uuid], array['dashboard']);
select public.save_product(null, '{"syt_code":"P50","name":"Batch4 item 4kg","factor":"4","cost_per_uom":"3"}'::jsonb) as _ \gset
select public.save_product(null, '{"syt_code":"P51","name":"Batch4 item 1kg","factor":"1","cost_per_uom":"1"}'::jsonb) as _ \gset
select public.save_product(null, '{"syt_code":"P52","name":"Batch4 zero item","factor":"2","cost_per_uom":"1"}'::jsonb) as _ \gset
select public.save_product(null, '{"syt_code":"P53","name":"Batch4 opening item","factor":"1","cost_per_uom":"1"}'::jsonb) as _ \gset
select testh.logout();

-- ===== 1) وجهات التحويل: المستخدم بيشوف كل المطابخ كوجهة، وبيبعت لمطبخ مش بتاعه =====
select testh.login('ku50@breadfast.com');
select testh.assert_eq('kitchen user sees only own kitchen in Branch (RLS)', (select count(*) from public.kitchens), 1::bigint);
select testh.assert_eq('...but all active kitchens as transfer targets', (select count(*) from public.transfer_kitchens()), 4::bigint);
select public.save_document(null, 'PURCHASE', :'k_rehab', '2027-07-01', null, jsonb_build_array(testh.line('P50', '40'), testh.line('P51', '10'))) as pu \gset
select public.post_document(:'pu'::uuid);
select public.save_document(null, 'TRANSFER', :'k_rehab', '2027-07-02', null, jsonb_build_array(testh.line('P50', '8')), :'k_maadi'::uuid) as tr \gset
select public.post_document(:'tr'::uuid);
select testh.assert_eq('transfer to a kitchen the sender does not belong to is sent', (select status from public.documents where id = :'tr'), 'PENDING_RECEIPT');
select testh.logout();
select testh.login('vw50@breadfast.com');
select testh.assert_eq('viewer without kitchens_transfer page gets no targets', (select count(*) from public.transfer_kitchens()), 0::bigint);
select testh.logout();

-- ===== 2) المشتريات بعد الـ Post: Admin بس =====
select testh.login('mg50@breadfast.com');
select testh.expect_err(format($$select public.reverse_document(%L, 'oops')$$, :'pu'), '%الـ Admin%');
select testh.logout();
select testh.login('ku50@breadfast.com');
select testh.expect_err(format($$select public.reverse_document(%L, 'oops')$$, :'pu'), '%الـ Admin%');
select testh.logout();
-- غير المشتريات: المدير لسه يقدر (waste مثلًا)
select testh.login('ku50@breadfast.com');
select public.save_document(null, 'WH_TXN', :'k_rehab', '2027-07-03', null, jsonb_build_array(testh.line('P51', '2'))) as wh \gset
select public.post_document(:'wh'::uuid);
select testh.logout();
select testh.login('mg50@breadfast.com');
select public.reverse_document(:'wh'::uuid, 'wrong entry') as _ \gset
select testh.assert_eq('manager can still reverse non-purchase documents', (select status from public.documents where id = :'wh'), 'REVERSED');
select testh.logout();
select testh.login('ku50@breadfast.com');
select public.save_document(null, 'PURCHASE', :'k_rehab', '2027-07-04', null, jsonb_build_array(testh.line('P51', '5'))) as pu2 \gset
select public.post_document(:'pu2'::uuid);
select testh.logout();
select testh.login('mohamed.mahmoudsalah@breadfast.com');
select public.reverse_document(:'pu2'::uuid, 'admin fix') as _ \gset
select testh.assert_eq('admin can reverse a posted purchase', (select status from public.documents where id = :'pu2'), 'REVERSED');
select testh.logout();

-- ===== 3) Opening Balance بصفر =====
select testh.login('mohamed.mahmoudsalah@breadfast.com');
select public.set_user_access((select user_id from public.profiles where email = 'ku50@breadfast.com'), 'kitchen_user', true,
  array[:'k_rehab'::uuid], (select array_agg(key) from public.pages where key <> 'access_control'));
select testh.logout();
select testh.login('ku50@breadfast.com');
select testh.stage('opening', :'k_rehab', '[
  {"date":"2027-08-01","code":"P52","qty":"-1"}
]'::jsonb, 'BASE') as op_neg \gset
select testh.assert_eq('negative opening is still rejected', (select error_count from public.import_batches where id = :'op_neg'), 1);
select testh.logout();
select testh.login('ku50@breadfast.com');
select testh.stage('opening', :'k_rehab', '[
  {"date":"2027-08-01","code":"P52","qty":"0"},
  {"date":"2027-08-01","code":"P53","qty":"12.5"}
]'::jsonb, 'BASE') as op_ok \gset
select testh.assert_eq('opening with a zero row validates', (select error_count from public.import_batches where id = :'op_ok'), 0);
select public.import_commit(:'op_ok'::uuid) as res \gset
select testh.assert_eq('opening doc has both lines (zero kept on the document)',
  (select count(*) from public.document_lines l join public.documents d on d.id = l.document_id where d.import_batch_id = :'op_ok'), 2::bigint);
select testh.assert_eq('zero row did not touch stock, other row did',
  testh.bal('REHAB', 'WAREHOUSE', 'P52')::text || '/' || testh.bal('REHAB', 'WAREHOUSE', 'P53')::text, '0/12.5000');
select testh.assert_eq('zero row made no ledger movement',
  (select count(*) from public.stock_ledger where product_id = (select id from public.products where syt_code = 'P52') and kitchen_id = :'k_rehab'), 0::bigint);
select testh.logout();
-- Purchases/Waste لسه ممنوع فيها الصفر
select testh.login('ku50@breadfast.com');
select testh.stage('purchases', :'k_rehab', '[{"date":"2027-08-02","code":"P52","qty":"0"}]'::jsonb, 'BASE') as pu0 \gset
select testh.assert_eq('zero purchase row is accepted now (010)', (select error_count from public.import_batches where id = :'pu0'), 0);
select testh.logout();

-- ===== 4) Product Card =====
select testh.login('ku50@breadfast.com');
select testh.expect_err(format($$select * from public.product_card((select id from public.products where syt_code = 'P50'))$$), '%Admin أو الـ Manager%');
select testh.logout();
select testh.login('mg50@breadfast.com');
select testh.assert_eq('manager card for P50 in Rehab: purchase (+40) then transfer out (-8)',
  (select string_agg(movement_type || ':' || qty_base::numeric(18,2)::text, ',' order by at, movement_type)
     from public.product_card((select id from public.products where syt_code = 'P50'), :'k_rehab') where location = 'WAREHOUSE'),
  'PURCHASE:40.00,TRANSFER_OUT:-8.00');
select testh.assert_eq('card carries pieces + who did it',
  (select qty_pieces::numeric(18,2)::text || '/' || user_email from public.product_card((select id from public.products where syt_code = 'P50'), :'k_rehab')
    where movement_type = 'TRANSFER_OUT'), '-2.00/ku50@breadfast.com');
select testh.assert_eq('running warehouse balance after the transfer = 32',
  (select balance_after::numeric(18,2) from public.product_card((select id from public.products where syt_code = 'P50'), :'k_rehab')
    where movement_type = 'TRANSFER_OUT'), 32.00);
select testh.assert_eq('manager sees no other kitchen rows (only Rehab)',
  (select count(*) from public.product_card((select id from public.products where syt_code = 'P51')) where kitchen <> 'Rehab'), 0::bigint);
select testh.assert_eq('date filter works',
  (select count(*) from public.product_card((select id from public.products where syt_code = 'P50'), :'k_rehab', '2027-07-02', '2027-07-02')
    where movement_type = 'TRANSFER_OUT'), 1::bigint);
select testh.logout();
select testh.login('mohamed.mahmoudsalah@breadfast.com');
select testh.assert_eq('admin card shows the opening row of P53 in Rehab',
  (select count(*) from public.product_card((select id from public.products where syt_code = 'P53')) where kitchen = 'Rehab' and movement_type = 'OPENING'), 1::bigint);
select testh.logout();


-- ===== 010: صفر في كل الصفحات + ترحيل الجرد للـ Admin بس =====
insert into auth.users (email) values ('ku60@breadfast.com');
select testh.login('mohamed.mahmoudsalah@breadfast.com');
select public.save_product(null, '{"syt_code":"P60","name":"Batch41 a","factor":"2","cost_per_uom":"1"}'::jsonb) as _ \gset
select public.save_product(null, '{"syt_code":"P61","name":"Batch41 b","factor":"1","cost_per_uom":"1"}'::jsonb) as _ \gset
select public.set_user_access((select user_id from public.profiles where email = 'ku60@breadfast.com'), 'kitchen_user', true,
  array[:'k_maadi'::uuid], (select array_agg(key) from public.pages where key <> 'access_control'));
select testh.logout();
select testh.login('ku60@breadfast.com');
select testh.stage('purchases', :'k_maadi', '[{"date":"2027-09-01","code":"P60","qty":"0"},{"date":"2027-09-01","code":"P61","qty":"7"}]'::jsonb, 'BASE') as z1 \gset
select testh.assert_eq('purchase with a zero row validates', (select error_count from public.import_batches where id = :'z1'), 0);
select public.import_commit(:'z1'::uuid) as res \gset
select testh.assert_eq('zero purchase row: no stock, other row stocked', testh.bal('MAADI','WAREHOUSE','P60')::text || '/' || testh.bal('MAADI','WAREHOUSE','P61')::text, '0/7.0000');
select testh.stage('purchases', :'k_maadi', '[{"date":"2027-09-01","code":"P60","qty":"-1"}]'::jsonb, 'BASE') as z2 \gset
select testh.assert_eq('negative purchase rejected', (select error_count from public.import_batches where id = :'z2'), 1);
select testh.stage('waste', :'k_maadi', '[{"date":"2027-09-02","code":"P61","qty":"0","reason":"Damage"}]'::jsonb, 'BASE') as z3 \gset
select testh.assert_eq('zero waste validates', (select error_count from public.import_batches where id = :'z3'), 0);
select public.import_commit(:'z3'::uuid) as res \gset
select testh.assert_eq('zero waste leaves stock', testh.bal('MAADI','WAREHOUSE','P61'), 7.0000);
select testh.stage('adjustments', :'k_maadi', '[{"date":"2027-09-02","code":"P61","qty":"0","reason":"Count Correction"}]'::jsonb, 'BASE') as z4 \gset
select testh.assert_eq('zero adjustment validates', (select error_count from public.import_batches where id = :'z4'), 0);
select testh.stage('transfers', :'k_maadi', '[{"date":"2027-09-03","to":"Rehab","code":"P60","qty":"0"},{"date":"2027-09-03","to":"Rehab","code":"P61","qty":"2"}]'::jsonb, 'BASE') as z5 \gset
select public.import_commit(:'z5'::uuid) as res \gset
select testh.assert_eq('transfer with a zero line sends only the real one',
  (select count(*) from public.transfer_lines t join public.documents d on d.id = t.document_id where d.import_batch_id = :'z5'), 1::bigint);
select testh.assert_eq('transfer zero line kept on the document',
  (select count(*) from public.document_lines l join public.documents d on d.id = l.document_id where d.import_batch_id = :'z5'), 2::bigint);
select testh.stage('transfers', :'k_maadi', '[{"date":"2027-09-04","to":"Rehab","code":"P60","qty":"0"}]'::jsonb, 'BASE') as z6 \gset
select testh.expect_err(format($$select public.import_commit(%L)$$, :'z6'), '%كميات صفر%');
-- ترحيل الجرد
select public.save_document(null, 'CLOSING', :'k_maadi', '2027-09-30', null, jsonb_build_array(testh.line('P61', '3'))) as cl \gset
select testh.expect_err(format($$select public.post_document(%L, null, false)$$, :'cl'), '%للـ Admin بس%');
select public.post_document(:'cl'::uuid);
select testh.assert_eq('non-admin closing carries the count (stock = count)', testh.bal('MAADI','WAREHOUSE','P61') - 2, 3.0000 - 2);
select testh.logout();
select testh.login('mohamed.mahmoudsalah@breadfast.com');
select public.save_document(null, 'CLOSING', :'k_maadi', '2027-10-31', null, jsonb_build_array(testh.line('P61', '1'))) as cl2 \gset
select public.post_document(:'cl2'::uuid, null, false);
select testh.assert_eq('admin may skip carrying the count', (select status from public.documents where id = :'cl2'), 'POSTED');
select testh.logout();


-- ===== 011: documents_search =====
select testh.login('ku60@breadfast.com');
select testh.assert_eq('search by product code finds the purchase', (select count(*) from public.documents_search('PURCHASE', :'k_maadi', '2027-01-01', '2027-12-31', 'own', false, 'P61')), 1::bigint);
select testh.assert_eq('search by product name (case-insensitive)', (select count(*) from public.documents_search('PURCHASE', :'k_maadi', '2027-01-01', '2027-12-31', 'own', false, 'batch41 B')), 1::bigint);
select testh.assert_eq('search misses unrelated text', (select count(*) from public.documents_search('PURCHASE', :'k_maadi', '2027-01-01', '2027-12-31', 'own', false, 'zzz')), 0::bigint);
select testh.assert_eq('wildcard chars are literal', (select count(*) from public.documents_search('PURCHASE', :'k_maadi', '2027-01-01', '2027-12-31', 'own', false, '%')), 0::bigint);
select testh.assert_eq('status filter matches a plain query',
  (select count(*) from public.documents_search('PURCHASE', :'k_maadi', '2027-01-01', '2027-12-31', 'own', false, null, 'DRAFT')),
  (select count(*) from public.documents where doc_type = 'PURCHASE' and kitchen_id = :'k_maadi' and status = 'DRAFT' and reverses_document_id is null and doc_date between '2027-01-01' and '2027-12-31'));
select testh.assert_eq('paging: limit 1 returns one row but the full total',
  (select count(*)::text || '/' || max(total_count)::text from public.documents_search('CLOSING', :'k_maadi', '2027-01-01', '2027-12-31', 'own', false, null, null, 1, 0)),
  '1/' || (select count(*) from public.documents where doc_type = 'CLOSING' and kitchen_id = :'k_maadi' and reverses_document_id is null and doc_date between '2027-01-01' and '2027-12-31')::text);
select testh.assert_eq('RLS still applies (other kitchen sees nothing)', (select count(*) from public.documents_search('PURCHASE', :'k_plus', '2027-01-01', '2027-12-31', 'own')), 0::bigint);
select testh.logout();
select testh.login('ku50@breadfast.com');
select testh.assert_eq('receiver sees the incoming transfer (sent from Maadi) and own outgoing one',
  (select count(*) from public.documents_search('TRANSFER', :'k_rehab', '2027-01-01', '2027-12-31', 'incoming'))::text || '/' ||
  (select count(*) from public.documents_search('TRANSFER', :'k_rehab', '2027-01-01', '2027-12-31', 'own'))::text, '1/1');
select testh.logout();

\echo ALL BATCH-4 SQL TESTS PASSED

-- اختبارات الدفعة 3 (بتشتغل بعد 10 و 20 على نفس الـ DB). مطبخ NC7 نضيف لعزل السيناريو.
\set ON_ERROR_STOP on
\set QUIET on

select id as k_nc7 from public.kitchens where code = 'NC7' \gset
select id as k_plus from public.kitchens where code = 'PLUS_MALL' \gset
select id as k_maadi from public.kitchens where code = 'MAADI' \gset

insert into auth.users (email) values ('nina@breadfast.com');
select testh.login('mohamed.mahmoudsalah@breadfast.com');
select public.set_user_access((select user_id from public.profiles where email = 'nina@breadfast.com'), 'manager', true,
  array[:'k_nc7'::uuid], (select array_agg(key) from public.pages where key <> 'access_control'));
select public.save_product(null, '{"syt_code":"N1","name":"NC7 item 2kg","factor":"2","cost_per_uom":"5"}'::jsonb) as _ \gset
select public.save_product(null, '{"syt_code":"N2","name":"NC7 item 1kg","factor":"1","cost_per_uom":"2"}'::jsonb) as _ \gset
select testh.logout();

-- ===================== 1) Closing شهر = Opening الشهر اللي بعده =====================
select testh.login('nina@breadfast.com');
select public.save_document(null, 'PURCHASE', :'k_nc7', '2027-02-01', null, jsonb_build_array(testh.line('N1', '100'), testh.line('N2', '50'))) as p1 \gset
select public.post_document(:'p1'::uuid);
select public.save_document(null, 'CLOSING', :'k_nc7', '2027-02-28', 'Feb count', jsonb_build_array(testh.line('N1', '90'), testh.line('N2', '50'))) as c_feb \gset
select public.post_document(:'c_feb'::uuid);
select testh.assert_eq('Feb: consumption = 0 + 100 - 90 (N1)',
  (select concat_ws('/', opening::numeric(18,4), purchases::numeric(18,4), closing::numeric(18,4), consumption::numeric(18,4))
     from public.report_consumption(:'k_nc7', '2027-02-01', '2027-02-28') where syt_code = 'N1'), '0.0000/100.0000/90.0000/10.0000');
select testh.assert_eq('only the differing product got a variance line (N2 matched the count)',
  (select count(*) from public.document_lines l join public.documents d on d.id = l.document_id where d.source_document_id = :'c_feb'), 1::bigint);

select public.save_document(null, 'PURCHASE', :'k_nc7', '2027-03-05', null, jsonb_build_array(testh.line('N1', '20'))) as p2 \gset
select public.post_document(:'p2'::uuid);
select public.save_document(null, 'CLOSING', :'k_nc7', '2027-03-31', 'Mar count', jsonb_build_array(testh.line('N1', '100'))) as c_mar \gset
select public.post_document(:'c_mar'::uuid);
select testh.assert_eq('March opening = Feb closing count (N1: 90), consumption = 90 + 20 - 100',
  (select concat_ws('/', opening::numeric(18,4), purchases::numeric(18,4), closing::numeric(18,4), consumption::numeric(18,4))
     from public.report_consumption(:'k_nc7', '2027-03-01', '2027-03-31') where syt_code = 'N1'), '90.0000/20.0000/100.0000/10.0000');
select testh.assert_eq('March: N2 opening = Feb count (50); not in March count => closing 0 => consumption 50',
  (select concat_ws('/', opening::numeric(18,4), closing::numeric(18,4), consumption::numeric(18,4))
     from public.report_consumption(:'k_nc7', '2027-03-01', '2027-03-31') where syt_code = 'N2'), '50.0000/0.0000/50.0000');
select testh.assert_eq('warehouse stock March: opening 90 -> stock = counted 100 (variance -10 shown as adjustment)',
  (select concat_ws('/', opening::numeric(18,4), purchases::numeric(18,4), adjustments::numeric(18,4), closing_book::numeric(18,4))
     from public.report_warehouse_stock(:'k_nc7', '2027-03-01', '2027-03-31') where syt_code = 'N1'), '90.0000/20.0000/-10.0000/100.0000');

-- بدون تطبيق الفروق على المخزون
select public.save_document(null, 'CLOSING', :'k_nc7', '2027-04-30', 'no apply', jsonb_build_array(testh.line('N1', '5'))) as c_apr \gset
select public.post_document(:'c_apr'::uuid, null, false);
select testh.logout();
select testh.assert_eq('apply=false leaves stock untouched and creates no adjustment',
  testh.bal('NC7', 'WAREHOUSE', 'N1')::text || '/' || (select count(*) from public.documents where source_document_id = :'c_apr')::text, '100.0000/0');

-- ===================== 2) مرتجع مرجعش فعلًا: رجّعه استوك وبعدين Missing =====================
select testh.login('nina@breadfast.com');
select public.save_document(null, 'TRANSFER', :'k_nc7', '2027-05-01', null, jsonb_build_array(testh.line('N1', '30')), :'k_plus') as tw \gset
select public.post_document(:'tw'::uuid);
select testh.logout();
select testh.login('ali@breadfast.com');
select id as lw from public.document_lines where document_id = :'tw' and line_no = 1 \gset
select public.receive_transfer(:'tw'::uuid, jsonb_build_array(jsonb_build_object('line_id', :'lw', 'qty', '20')), '2027-05-02');
select testh.expect_err(format($$select public.write_off_return(%L, '2027-05-03')$$, :'tw'), '%المرسل%');
select testh.logout();

select testh.login('nina@breadfast.com');
select testh.expect_err(format($$select public.write_off_return(%L, '2027-05-03')$$, :'k_nc7'), '%مش موجود%');
select testh.logout();
-- بدون صلاحية Stock Adjustments مينفعش
select testh.login('mohamed.mahmoudsalah@breadfast.com');
select public.set_user_access((select user_id from public.profiles where email = 'nina@breadfast.com'), 'manager', true,
  array[:'k_nc7'::uuid], (select array_agg(key) from public.pages where key not in ('access_control', 'stock_adjustments')));
select testh.logout();
select testh.login('nina@breadfast.com');
select testh.expect_err(format($$select public.write_off_return(%L, '2027-05-03')$$, :'tw'), '%Stock Adjustments%');
select testh.logout();
select testh.login('mohamed.mahmoudsalah@breadfast.com');
select public.set_user_access((select user_id from public.profiles where email = 'nina@breadfast.com'), 'manager', true,
  array[:'k_nc7'::uuid], (select array_agg(key) from public.pages where key <> 'access_control'));
select testh.logout();

select testh.login('nina@breadfast.com');
select testh.assert_eq('before write-off: 10 pending return, stock 70',
  (select status from public.documents where id = :'tw'), 'RETURN_PENDING');
select public.write_off_return(:'tw'::uuid, '2027-05-03') as adj_w \gset
select testh.logout();
select testh.assert_eq('write-off closes the transfer', (select status from public.documents where id = :'tw'), 'CLOSED_PARTIAL');
select testh.assert_eq('returned to stock then booked as Missing: NC7 N1 = 100 - 30 + 10 - 10 = 70, nothing pending',
  testh.bal('NC7', 'WAREHOUSE', 'N1')::text || '/' || testh.bal('NC7', 'RETURN_PENDING', 'N1')::text, '70.0000/0.0000');
select testh.assert_eq('Missing adjustment linked to the transfer',
  (select d.status || ':' || l.reason || ':' || l.qty_base::text from public.documents d join public.document_lines l on l.document_id = d.id
    where d.id = :'adj_w' and d.source_document_id = :'tw'), 'POSTED:Missing:-10.0000');
select testh.assert_eq('stock accounting: receiver 20 + sender 70 = 90 (10 written off)',
  (select sum(b.qty_base) from public.stock_balances b join public.products p on p.id = b.product_id where p.syt_code = 'N1' and b.kitchen_id in (:'k_nc7', :'k_plus')), 90::numeric);
select testh.login('nina@breadfast.com');
select testh.expect_err(format($$select public.write_off_return(%L, '2027-05-04')$$, :'tw'), '%مفيهوش مرتجع%');
select testh.logout();

-- ===================== 3) Import التحويلات من ملف =====================
select testh.login('nina@breadfast.com');
select testh.stage('transfers', :'k_nc7', '[
  {"date":"2027-05-10","to":"Plus Mall","code":"N2","qty":"5"},
  {"date":"2027-05-10","to":"Maadi","code":"N2","qty":"3"},
  {"date":"2027-05-10","to":"Nowhere","code":"N2","qty":"1"},
  {"date":"2027-05-10","to":"NC7","code":"N2","qty":"1"},
  {"date":"2027-05-10","code":"N2","qty":"1"},
  {"date":"2027-05-10","to":"Rehab","code":"N2","qty":"500"}
]'::jsonb, 'BASE') as tr_bad \gset
select testh.assert_eq('transfers import: unknown / self / missing receiver / over-balance => 4 errors',
  (select error_count from public.import_batches where id = :'tr_bad'), 4);
select testh.assert_eq('nothing sent from bad file', (select count(*) from public.documents where import_batch_id = :'tr_bad'), 0::bigint);
select testh.stage('transfers', :'k_nc7', '[
  {"date":"2027-05-10","to":"plus mall","code":"N2","qty":"5"},
  {"date":"2027-05-10","to":"PLUS_MALL","code":"N1","qty":"4"},
  {"date":"2027-05-10","to":"Maadi","code":"N2","qty":"3"}
]'::jsonb, 'BASE') as tr_ok \gset
select public.import_commit(:'tr_ok'::uuid) as res \gset
select testh.logout();
select testh.assert_eq('one transfer per receiver, both waiting for receipt',
  (select string_agg(k.code || ':' || d.status || ':' || (select count(*) from public.document_lines l where l.document_id = d.id)::text, ',' order by k.code)
     from public.documents d join public.kitchens k on k.id = d.counterpart_kitchen_id where d.import_batch_id = :'tr_ok'),
  'MAADI:PENDING_RECEIPT:1,PLUS_MALL:PENDING_RECEIPT:2');
select testh.assert_eq('imported transfers moved stock to In Transit',
  testh.bal('NC7', 'WAREHOUSE', 'N2')::text || '/' || testh.bal('NC7', 'IN_TRANSIT', 'N2')::text, '42.0000/8.0000');
select testh.login('ali@breadfast.com');
select testh.assert_eq('receiver sees the imported transfer', (select count(*) from public.documents d where d.import_batch_id = :'tr_ok'), 1::bigint);
select testh.logout();
select testh.login('viewer1@breadfast.com');
select testh.expect_err(format($$select public.import_start('transfers', %L, 'x.xlsx', 1)$$, :'k_maadi'), '%مش مسموحلك%');
select testh.logout();

-- ===================== 4) Dashboard =====================
select testh.login('nina@breadfast.com');
select public.dashboard_summary(:'k_nc7') as dash \gset
select testh.logout();
select testh.assert_eq('dashboard: outgoing transfers waiting = 2 (imported) ',
  (:'dash'::jsonb ->> 'outgoing_pending')::int, 2);
select testh.assert_eq('dashboard: stock value NC7 = N1 66*5 + N2 42*2 = 414',
  (:'dash'::jsonb ->> 'stock_value')::numeric, 414::numeric);
select testh.assert_eq('dashboard: last closing is the April no-apply count', (:'dash'::jsonb ->> 'last_closing'), '2027-04-30');
select testh.assert_eq('dashboard: pending_users visible to manager', (:'dash'::jsonb ->> 'pending_users') is not null, true);
select testh.login('ali@breadfast.com');
select testh.assert_eq('dashboard: pending_users hidden from kitchen user', (public.dashboard_summary(:'k_plus') ->> 'pending_users') is null, true);
select testh.assert_eq('dashboard: incoming to confirm for receiver', (public.dashboard_summary(:'k_plus') ->> 'incoming_to_confirm')::int, 1);
select testh.expect_err(format($$select public.dashboard_summary(%L)$$, :'k_nc7'), '%مش مسموحلك%');
select testh.logout();
select testh.login('mohamed.mahmoudsalah@breadfast.com');
select testh.assert_eq('dashboard: admin sees pending users count', (public.dashboard_summary(:'k_nc7') ->> 'pending_users') is not null, true);
select testh.logout();

\echo ALL BATCH-3 SQL TESTS PASSED

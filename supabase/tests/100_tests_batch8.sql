-- اختبارات 016: إعادة الضبط الكاملة (آخر ملف: بيمسح كل حاجة)
\set ON_ERROR_STOP on
\set QUIET on

select id as k_maadi from public.kitchens where code = 'MAADI' \gset
select (select count(*) from public.profiles) as n_profiles \gset
select (select count(*) from public.reasons) as n_reasons \gset

select testh.login('ku70@breadfast.com');
select testh.expect_err($$select public.reset_all_data('2003')$$, '%Admin بس%');
select testh.logout();
select testh.login('mohamed.mahmoudsalah@breadfast.com');
select testh.expect_err($$select public.reset_all_data('1234')$$, '%كلمة السر غلط%');
select testh.expect_err($$select public.reset_all_data(null)$$, '%كلمة السر غلط%');
select testh.assert_eq('nothing wiped by wrong passwords', (select count(*) > 0 from public.documents), true);
select public.reset_all_data('2003') as res \gset
select testh.assert_eq('report counted what was wiped', (:'res'::jsonb ->> 'documents')::int > 0, true);
select testh.logout();

select testh.assert_eq('transactional data gone',
  (select (select count(*) from public.documents) + (select count(*) from public.document_lines) + (select count(*) from public.stock_ledger)
        + (select count(*) from public.stock_balances) + (select count(*) from public.periods) + (select count(*) from public.products)
        + (select count(*) from public.import_batches) + (select count(*) from public.import_rows) + (select count(*) from public.import_errors)
        + (select count(*) from public.purge_log)), 0::bigint);
select testh.assert_eq('audit log holds only the reset trace', (select string_agg(action, ',') from public.audit_log), 'ADMIN_RESET_ALL');
select testh.assert_eq('users and access kept', (select count(*) from public.profiles), :n_profiles::bigint);
select testh.assert_eq('kitchens kept', (select count(*) from public.kitchens), 4::bigint);
select testh.assert_eq('reasons kept', (select count(*) from public.reasons), :n_reasons::bigint);

-- النظام شغّال من جديد والترقيم بيبدأ من 1
select testh.login('mohamed.mahmoudsalah@breadfast.com');
select public.save_product(null, '{"syt_code":"NEW1","name":"Fresh start","factor":"1","cost_per_uom":"1"}'::jsonb) as _ \gset
select public.save_document(null, 'PURCHASE', :'k_maadi', '2026-10-13', null, jsonb_build_array(testh.line('NEW1', '10'))) as nd \gset
select public.post_document(:'nd'::uuid);
select testh.assert_eq('numbering restarted', (select doc_no from public.documents where id = :'nd'), 'PUR-000001');
select testh.assert_eq('balances work again', testh.bal('MAADI', 'WAREHOUSE', 'NEW1'), 10.0000);
select testh.logout();

\echo ALL BATCH-8 SQL TESTS PASSED

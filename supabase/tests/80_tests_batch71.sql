-- اختبارات 014: مسح فترة غير مقفولة (بيقفلها تلقائيًا) + مسح الجرد للـ Admin بس
\set ON_ERROR_STOP on
\set QUIET on

select id as k_maadi from public.kitchens where code = 'MAADI' \gset
select id as k_rehab from public.kitchens where code = 'REHAB' \gset
insert into auth.users (email) values ('ku95@breadfast.com');
select testh.login('mohamed.mahmoudsalah@breadfast.com');
select public.set_user_access((select user_id from public.profiles where email = 'ku95@breadfast.com'), 'kitchen_user', true,
  array[:'k_maadi'::uuid], (select array_agg(key) from public.pages where key <> 'access_control'));
select public.save_product(null, '{"syt_code":"D95","name":"Del closing","factor":"1","cost_per_uom":"1"}'::jsonb) as _ \gset
select testh.logout();

-- ===== مسح الجرد =====
select testh.login('ku95@breadfast.com');
select public.save_document(null, 'PURCHASE', :'k_maadi', '2026-08-05', null, jsonb_build_array(testh.line('D95', '100'))) as p1 \gset
select public.post_document(:'p1'::uuid);
select public.save_document(null, 'CLOSING', :'k_maadi', '2026-08-31', null, jsonb_build_array(testh.line('D95', '70'))) as c1 \gset
select public.post_document(:'c1'::uuid);
select testh.logout();
select testh.assert_eq('count of 70 against book 100 -> stock 70', testh.bal('MAADI', 'WAREHOUSE', 'D95'), 70.0000);

select testh.login('ku95@breadfast.com');
select testh.expect_err(format($$select public.delete_closing(%L, 'wrong upload')$$, :'c1'), '%للـ Admin بس%');
select testh.logout();
select testh.login('mohamed.mahmoudsalah@breadfast.com');
select public.close_period(:'k_maadi'::uuid, '2026-08-01', '2026-08-31') as _ \gset
select testh.expect_err(format($$select public.delete_closing(%L, '')$$, :'c1'), '%سبب المسح%');
select testh.expect_err(format($$select public.delete_closing(%L, 'x')$$, :'p1'), '%مش مستند جرد%');
select public.delete_closing(:'c1'::uuid, 'uploaded by mistake') as res \gset
select testh.assert_eq('closing + its adjustment deleted (2 docs)', (:'res'::jsonb ->> 'documents_deleted'), '2');
select testh.assert_eq('stock back to 100 even though the period is closed', testh.bal('MAADI', 'WAREHOUSE', 'D95'), 100.0000);
select testh.assert_eq('closing doc is gone', (select count(*) from public.documents where id = :'c1'), 0::bigint);
select testh.assert_eq('deletion is audited', (select count(*) from public.audit_log where action = 'ADMIN_DELETE_CLOSING' and row_id = :'c1'), 1::bigint);
-- جرد جديد صح بعد المسح (الأدمن بسبب لأن الفترة مقفولة)
select public.save_document(null, 'CLOSING', :'k_maadi', '2026-08-31', null, jsonb_build_array(testh.line('D95', '120'))) as c2 \gset
select public.post_document(:'c2'::uuid, 'corrected count');
select testh.assert_eq('admin can re-enter the right closing', testh.bal('MAADI', 'WAREHOUSE', 'D95'), 120.0000);

-- حركة بعد الجرد اعتمدت على تسويته: المسح مرفوض بدل ما الرصيد يبقى سالب
select public.save_document(null, 'WH_TXN', :'k_maadi', '2026-09-02', null, jsonb_build_array(testh.line('D95', '120'))) as w1 \gset
select public.post_document(:'w1'::uuid);
select testh.expect_err(format($$select public.delete_closing(%L, 'x')$$, :'c2'), '%سالب%');
select testh.logout();

-- ===== مسح فترة مش مقفولة: بيتقفل تلقائيًا =====
select testh.login('mohamed.mahmoudsalah@breadfast.com');
select public.save_document(null, 'PURCHASE', :'k_rehab', '2026-01-10', null, jsonb_build_array(testh.line('D95', '5'))) as r1 \gset
select public.post_document(:'r1'::uuid);
select testh.assert_eq('January has no closed period', public.is_period_closed(:'k_rehab'::uuid, '2026-01-10'), false);
select (select (public.purge_preview('2026-01-01', '2026-01-31') ->> 'ok')) as ok \gset
select testh.assert_eq('preview ok without a closed period', :'ok'::text, 'true');
select public.purge_range('2026-01-01', '2026-01-31', 'PURGE 2026-01 → 2026-01') as pres \gset
select testh.assert_eq('purged', (:'pres'::jsonb ->> 'documents'), '1');
select testh.assert_eq('period locked automatically for all active kitchens', (:'pres'::jsonb ->> 'periods_locked')::int >= 4, true);
select testh.assert_eq('rehab January is closed now', public.is_period_closed(:'k_rehab'::uuid, '2026-01-20'), true);
select testh.assert_eq('maadi January is closed now', public.is_period_closed(:'k_maadi'::uuid, '2026-01-01'), true);
select testh.assert_eq('stock kept (carry-forward)', testh.bal('REHAB', 'WAREHOUSE', 'D95'), 5.0000);
select testh.logout();
select testh.login('ku95@breadfast.com');
select testh.expect_err(format($$select public.save_document(null, 'PURCHASE', %L, '2026-01-15', null, '[{"syt":"D95","qty":"1"}]'::jsonb)$$, :'k_maadi'), '%ارجع للـ Admin%');
select testh.logout();

\echo ALL BATCH-7.1 SQL TESTS PASSED

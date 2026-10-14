-- اختبارات 015: إعادة قفل فترة اتفتحت
\set ON_ERROR_STOP on
\set QUIET on

select id as k_nc7 from public.kitchens where code = 'NC7' \gset
select testh.login('mohamed.mahmoudsalah@breadfast.com');

select public.close_period(:'k_nc7'::uuid, '2025-05-01', '2025-05-31') as p_may \gset
select public.reopen_period(:'p_may'::uuid, 'wrong closing uploaded');
select testh.assert_eq('reopened', (select status from public.periods where id = :'p_may'), 'OPEN');
select testh.assert_eq('open period does not lock', public.is_period_closed(:'k_nc7'::uuid, '2025-05-10'), false);

-- إعادة القفل: نفس الصف بيتقفل (مفيش صف جديد ولا خطأ تداخل)
select public.close_period(:'k_nc7'::uuid, '2025-05-01', '2025-05-31') as again \gset
select testh.assert_eq('same row re-closed', :'again'::uuid = :'p_may'::uuid, true);
select testh.assert_eq('closed again', (select status || '/' || coalesce(reopen_reason, '-') from public.periods where id = :'p_may'), 'CLOSED/-');
select testh.assert_eq('only one row for May', (select count(*) from public.periods where kitchen_id = :'k_nc7' and from_date = '2025-05-01'), 1::bigint);
select testh.assert_eq('locks again', public.is_period_closed(:'k_nc7'::uuid, '2025-05-10'), true);

-- فترة مقفولة بالفعل: رسالة واضحة
select testh.expect_err(format($$select public.close_period(%L, '2025-05-01', '2025-06-30')$$, :'k_nc7'), '%بتتداخل مع فترة مقفولة قبل كده (2025-05-01 → 2025-05-31)%');

-- مفتوحة واسعة (مايو-يونيو) وبنقفل مايو بس: خطأ واضح
select public.close_period(:'k_nc7'::uuid, '2025-07-01', '2025-08-31') as p_ja \gset
select public.reopen_period(:'p_ja'::uuid, 'x');
select testh.expect_err(format($$select public.close_period(%L, '2025-07-01', '2025-07-31')$$, :'k_nc7'), '%بتتخطى الفترة المطلوبة%');
-- نقفلها بنفس حدودها + شهر جديد بعدها: الصف المفتوح بيتقفل وبيتضاف صف لسبتمبر
select public.close_period(:'k_nc7'::uuid, '2025-07-01', '2025-08-31') as _ \gset
select public.close_period(:'k_nc7'::uuid, '2025-09-01', '2025-09-30') as _ \gset
select testh.assert_eq('July-August closed again', (select status from public.periods where id = :'p_ja'), 'CLOSED');

-- مفتوحة صغيرة جوه فترة جديدة أكبر: بتتقفل وبيتضاف الباقي
select public.reopen_period((select id from public.periods where kitchen_id = :'k_nc7' and from_date = '2025-09-01'), 'y');
select public.close_period(:'k_nc7'::uuid, '2025-09-01', '2025-10-31') as _ \gset
select testh.assert_eq('Sep reclosed + Oct added', (select string_agg(from_date::text || '..' || to_date::text || ':' || status, ',' order by from_date)
  from public.periods where kitchen_id = :'k_nc7' and from_date between '2025-09-01' and '2025-12-31'), '2025-09-01..2025-09-30:CLOSED,2025-10-01..2025-10-31:CLOSED');
select testh.logout();

\echo ALL BATCH-7.4 SQL TESTS PASSED

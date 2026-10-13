-- اختبارات 013: أولوية Syt Code في الـ Import + فحص الجرد وقت الـ Validate
\set ON_ERROR_STOP on
\set QUIET on

select id as k_maadi from public.kitchens where code = 'MAADI' \gset
insert into auth.users (email) values ('ku90@breadfast.com');
select testh.login('mohamed.mahmoudsalah@breadfast.com');
select public.set_user_access((select user_id from public.profiles where email = 'ku90@breadfast.com'), 'kitchen_user', true,
  array[:'k_maadi'::uuid], (select array_agg(key) from public.pages where key <> 'access_control'));
select public.save_product(null, '{"syt_code":"RM90","generic_code":"RM90","name":"Same code","factor":"1","cost_per_uom":"1"}'::jsonb) as _ \gset
select public.save_product(null, '{"syt_code":"RM90-C","generic_code":"RM90","name":"Other size","factor":"5","cost_per_uom":"1"}'::jsonb) as _ \gset
select public.save_product(null, '{"syt_code":"C90","name":"Closing item","factor":"1","cost_per_uom":"1"}'::jsonb) as _ \gset
select testh.logout();

select testh.login('ku90@breadfast.com');
-- Generic بيطابق أكتر من حجم: لسه خطأ واضح
select testh.stage('purchases', :'k_maadi', '[{"date":"2026-12-02","code":"RM90-X","qty":"1"}]'::jsonb, 'BASE') as bx \gset
select testh.assert_eq('unknown code still rejected', (select error_count from public.import_batches where id = :'bx'), 1);
-- Syt Code مطابق تمامًا بيعدّي حتى لو هو نفسه Generic لمنتج تاني
select testh.stage('purchases', :'k_maadi', '[{"date":"2026-12-02","code":"RM90","qty":"1"}]'::jsonb, 'BASE') as b1 \gset
select testh.assert_eq('exact Syt Code wins over generic matches', (select error_count from public.import_batches where id = :'b1'), 0);
select testh.stage('purchases', :'k_maadi', '[{"date":"2026-12-02","code":"RM90-C","qty":"1"}]'::jsonb, 'BASE') as b2 \gset
select testh.assert_eq('other size by its Syt Code', (select error_count from public.import_batches where id = :'b2'), 0);

-- ===== الجرد: شراء 100 يوم 1، استهلاك 100 يوم 20 =====
select public.save_document(null, 'PURCHASE', :'k_maadi', '2026-12-01', null, jsonb_build_array(testh.line('C90', '100'))) as p1 \gset
select public.post_document(:'p1'::uuid);
select public.save_document(null, 'WASTE', :'k_maadi', '2026-12-20', null, jsonb_build_array(testh.line('C90', '100', 'BASE', 'Damage'))) as w1 \gset
select public.post_document(:'w1'::uuid);
-- جرد يوم 10 = 20 (الدفتر 100 → نقص 80) والرصيد الحالي 0 → اترفض وقت الـ Validate
select testh.stage('closing', :'k_maadi', '[{"date":"2026-12-10","code":"C90","qty":"20"}]'::jsonb, 'BASE') as c1 \gset
select testh.assert_eq('closing that would drive stock negative is rejected at validation', (select error_count from public.import_batches where id = :'c1'), 1);
select testh.assert_eq('message explains it', (select reason like '%خصم النقص هيخليه سالب%' from public.import_errors where batch_id = :'c1' limit 1), true);
-- نفس الجرد لو بتاريخ بعد الاستهلاك (الدفتر 0): تمام
select testh.stage('closing', :'k_maadi', '[{"date":"2026-12-31","code":"C90","qty":"5"}]'::jsonb, 'BASE') as c2 \gset
select testh.assert_eq('closing after the movements is fine', (select error_count from public.import_batches where id = :'c2'), 0);
-- ولو الجرد اليدوي: الرسالة واضحة
select public.save_document(null, 'CLOSING', :'k_maadi', '2026-12-10', null, jsonb_build_array(testh.line('C90', '20'))) as c3 \gset
select testh.expect_err(format($$select public.post_document(%L)$$, :'c3'), '%خصم النقص هيخليه سالب%');
select testh.logout();

\echo ALL BATCH-7 SQL TESTS PASSED

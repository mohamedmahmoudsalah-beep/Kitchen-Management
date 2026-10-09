-- اختبارات 008: أي حساب جوجل يسجّل لكن ميدخلش قبل موافقة Admin/Manager، وحدود الـ Manager
\set ON_ERROR_STOP on
\set QUIET on

select id as k_plus from public.kitchens where code = 'PLUS_MALL' \gset
select id as k_maadi from public.kitchens where code = 'MAADI' \gset
select id as k_rehab from public.kitchens where code = 'REHAB' \gset
select user_id as u_ali from public.profiles where email = 'ali@breadfast.com' \gset
select user_id as u_nina from public.profiles where email = 'nina@breadfast.com' \gset
select user_id as u_root from public.profiles where is_root \gset

insert into auth.users (email) values ('guest1@gmail.com');
insert into auth.users (email) values ('guest2@outlook.com');
insert into auth.users (email) values ('mgr2@breadfast.com');
select user_id as u_g1 from public.profiles where email = 'guest1@gmail.com' \gset
select user_id as u_g2 from public.profiles where email = 'guest2@outlook.com' \gset
select user_id as u_mgr2 from public.profiles where email = 'mgr2@breadfast.com' \gset

select testh.assert_eq('no email-domain trigger on auth.users anymore',
  (select count(*) from pg_trigger where tgname = 'auth_users_email_domain'), 0::bigint);
select testh.assert_eq('any-domain sign-ups are inactive viewers',
  (select string_agg(email || ':' || is_active::text || ':' || role::text, ',' order by email) from public.profiles
    where email in ('guest1@gmail.com', 'guest2@outlook.com')), 'guest1@gmail.com:false:viewer,guest2@outlook.com:false:viewer');

-- ===== مستخدم معلق: ميشوفش ولا يعمل حاجة =====
select testh.login('guest1@gmail.com');
select testh.assert_eq('pending user sees no kitchens/products/documents',
  (select count(*) from public.kitchens) + (select count(*) from public.products) + (select count(*) from public.documents), 0::bigint);
select testh.expect_err(format($$select public.save_document(null, 'PURCHASE', %L, '2027-06-01', null, jsonb_build_array(testh.line('T1', '1')))$$, :'k_maadi'), '%مش مسموحلك%');
select testh.expect_err(format($$select public.set_user_access(%L, 'admin', true, '{}', '{}')$$, :'u_g1'), '%Admin أو الـ Manager%');
select testh.expect_err($$select public.invite_user('a@b.co','viewer',true,'{}','{}')$$, '%للـ Admin بس%');
select testh.logout();

-- ===== مين يشوف المعلقين =====
select testh.login('ali@breadfast.com');
select testh.assert_eq('kitchen user cannot see pending sign-ups', (select count(*) from public.profiles where email like 'guest%'), 0::bigint);
select testh.logout();
select testh.login('sara@breadfast.com');
select testh.assert_eq('manager sees pending sign-ups', (select count(*) from public.profiles where email in ('guest1@gmail.com', 'guest2@outlook.com')), 2::bigint);
select testh.assert_eq('manager does not see root, other kitchens users or other managers',
  (select count(*) from public.profiles where is_root or email in ('ali@breadfast.com', 'nina@breadfast.com')), 0::bigint);

-- المدير يوافق ويدّي صلاحياته
select public.set_user_access(:'u_g1'::uuid, 'kitchen_user', true, array[:'k_maadi'::uuid], array['purchases', 'waste']);

-- حدود المدير
select testh.expect_err(format($$select public.set_user_access(%L, 'manager', true, array[%L::uuid], '{}')$$, :'u_g2', :'k_maadi'), '%Viewer أو Kitchen User%');
select testh.expect_err(format($$select public.set_user_access(%L, 'admin', true, '{}', '{}')$$, :'u_g2'), '%Viewer أو Kitchen User%');
select testh.expect_err(format($$select public.set_user_access(%L, 'viewer', true, array[%L::uuid], '{}')$$, :'u_g2', :'k_plus'), '%مطابخك%');
select testh.expect_err(format($$select public.set_user_access(%L, 'viewer', true, '{}', '{}')$$, :'u_ali'), '%مش في نطاقك%');
select testh.expect_err(format($$select public.set_user_access(%L, 'viewer', true, '{}', '{}')$$, :'u_nina'), '%مش في نطاقك%');
select testh.expect_err(format($$select public.set_user_access(%L, 'viewer', false, '{}', '{}')$$, :'u_root'), '%مش في نطاقك%');
select testh.logout();

-- المستخدم اللي اتوافق عليه بيشوف مطبخه وصفحاته بس
select testh.login('guest1@gmail.com');
select testh.assert_eq('approved user sees only the granted kitchen', (select count(*) from public.kitchens), 1::bigint);
select public.save_document(null, 'PURCHASE', :'k_maadi', '2027-06-01', 'by guest', jsonb_build_array(testh.line('T1', '1'))) as g_doc \gset
select testh.expect_err(format($$select public.save_document(null, 'WH_TXN', %L, '2027-06-01', null, jsonb_build_array(testh.line('T1', '1')))$$, :'k_maadi'), '%مش مسموحلك%');
select testh.expect_err(format($$select public.save_document(null, 'PURCHASE', %L, '2027-06-01', null, jsonb_build_array(testh.line('T1', '1')))$$, :'k_plus'), '%مش مسموحلك%');
select testh.expect_err(format($$select public.set_user_access(%L, 'admin', true, '{}', '{}')$$, :'u_g1'), '%Admin أو الـ Manager%');
select testh.logout();

-- ===== مدير بصفحات محدودة ما يقدرش يدّي أكتر من اللي معاه =====
select testh.login('mohamed.mahmoudsalah@breadfast.com');
select public.set_user_access(:'u_mgr2'::uuid, 'manager', true, array[:'k_maadi'::uuid], array['purchases', 'waste']);
select testh.logout();
select testh.login('mgr2@breadfast.com');
select testh.expect_err(format($$select public.set_user_access(%L, 'kitchen_user', true, array[%L::uuid], array['purchases', 'stock_adjustments'])$$, :'u_g2', :'k_maadi'), '%صفحاتك%');
select public.set_user_access(:'u_g2'::uuid, 'kitchen_user', true, array[:'k_maadi'::uuid], array['purchases', 'waste']);
select testh.logout();

-- ===== المدير بيلمس نطاقه بس (اللي برا نطاقه بيفضل زي ما هو) =====
select testh.login('mohamed.mahmoudsalah@breadfast.com');
select public.set_user_access(:'u_g1'::uuid, 'kitchen_user', true, array[:'k_maadi'::uuid, :'k_rehab'::uuid], array['purchases', 'waste', 'consumption']);
select public.set_user_access(:'u_g2'::uuid, 'kitchen_user', true, array[:'k_maadi'::uuid], array['purchases', 'waste', 'consumption']);
select testh.logout();
select testh.login('sara@breadfast.com');
select public.set_user_access(:'u_g1'::uuid, 'kitchen_user', true, array[:'k_maadi'::uuid], array['purchases']);
select testh.logout();
select testh.assert_eq('manager removed only what is in her scope: REHAB kept, other pages removed (sara owns all pages)',
  (select string_agg(k.code, ',' order by k.code) from public.user_kitchens uk join public.kitchens k on k.id = uk.kitchen_id where uk.user_id = :'u_g1'),
  'MAADI,REHAB');
select testh.assert_eq('sara (all pages) reduced pages to purchases',
  (select string_agg(page_key, ',' order by page_key) from public.user_pages where user_id = :'u_g1'), 'purchases');
select testh.login('mgr2@breadfast.com');
select public.set_user_access(:'u_g2'::uuid, 'kitchen_user', true, array[:'k_maadi'::uuid], array['purchases']);
select testh.logout();
select testh.assert_eq('mgr2 removed waste (his scope) but kept consumption (outside his scope)',
  (select string_agg(page_key, ',' order by page_key) from public.user_pages where user_id = :'u_g2'), 'consumption,purchases');

-- المدير يعطّل مستخدم من نطاقه
select testh.login('sara@breadfast.com');
select public.set_user_access(:'u_g1'::uuid, 'kitchen_user', false, array[:'k_maadi'::uuid], array['purchases']);
select testh.logout();
select testh.login('guest1@gmail.com');
select testh.assert_eq('deactivated user sees nothing again', (select count(*) from public.kitchens), 0::bigint);
select testh.logout();

-- ===== دعوة مسبقة لأي إيميل =====
select testh.login('mohamed.mahmoudsalah@breadfast.com');
select public.invite_user('Consultant@Gmail.com', 'viewer', true, array[:'k_maadi'::uuid], array['warehouse_stock']);
select testh.logout();
insert into auth.users (email) values ('consultant@gmail.com');
select testh.assert_eq('invited non-breadfast email is active with the invited access',
  (select p.is_active::text || ':' || (select count(*) from public.user_kitchens k where k.user_id = p.user_id)::text
          || ':' || (select count(*) from public.user_pages u where u.user_id = p.user_id)::text from public.profiles p where p.email = 'consultant@gmail.com'), 'true:1:1');

\echo ALL ACCESS SQL TESTS PASSED

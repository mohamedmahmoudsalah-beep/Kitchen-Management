-- 017: إصلاح reset_all_data — Supabase بيفعّل pg_safeupdate اللي بيرفض DELETE من غير WHERE
-- التعديل الوحيد: كل delete بقى فيه "where true". باقي الدالة زي ما هي بالظبط (016).
-- تذكير: الدالة دي لازم تتشال قبل الإنتاج: drop function public.reset_all_data(text);

create or replace function public.reset_all_data(p_password text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v jsonb; v_email text;
begin
  if not public.is_admin() then raise exception 'إعادة الضبط للـ Admin بس'; end if;
  if md5(coalesce(p_password, '')) <> 'a591024321c5e2bdbd23ed35f0574dde' then raise exception 'كلمة السر غلط'; end if;

  v := jsonb_build_object(
    'documents', (select count(*) from public.documents), 'document_lines', (select count(*) from public.document_lines),
    'stock_ledger', (select count(*) from public.stock_ledger), 'periods', (select count(*) from public.periods),
    'products', (select count(*) from public.products), 'import_batches', (select count(*) from public.import_batches),
    'audit_log', (select count(*) from public.audit_log), 'purge_log', (select count(*) from public.purge_log));

  perform set_config('kms.purge', 'on', true);
  delete from public.stock_balances where true;
  delete from public.stock_ledger where true;
  delete from public.transfer_lines where true;
  delete from public.document_lines where true;
  delete from public.documents where true;
  delete from public.periods where true;
  delete from public.import_errors where true;
  delete from public.import_rows where true;
  delete from public.import_batches where true;
  delete from public.products where true;
  delete from public.audit_log where true;
  delete from public.purge_log where true;

  perform setval('public.doc_no_seq', 1, false);
  perform setval(pg_get_serial_sequence('public.stock_ledger', 'id'), 1, false);
  perform setval(pg_get_serial_sequence('public.audit_log', 'id'), 1, false);
  perform setval(pg_get_serial_sequence('public.purge_log', 'id'), 1, false);

  -- أثر واحد بس إن إعادة الضبط حصلت (ومين عملها)
  select email into v_email from public.profiles where user_id = auth.uid();
  insert into public.audit_log (user_id, user_email, table_name, row_id, action, old_data)
  values (auth.uid(), v_email, 'system', null, 'ADMIN_RESET_ALL', v);
  return v;
end $function$;

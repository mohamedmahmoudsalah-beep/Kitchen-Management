-- =====================================================================
-- KMS batch 8 / 016 — إعادة ضبط كاملة (Admin بس + كلمة سر): مسح كل البيانات اللي اتضافت والـ Logs، والنظام يبقى كأنه جديد.
-- بيفضل: المستخدمين والصلاحيات (profiles / user_kitchens / user_pages / invites)، المطابخ، الصفحات، أسباب الـ Waste/Adjustments.
-- بيتمسح: المستندات والسطور والتحويلات والحركات والأرصدة والفترات والمنتجات وسجل الـ Import والـ Audit والـ purge_log. الترقيم بيبدأ من 1.
-- ملحوظة: كلمة السر هنا تأكيد ضد الضغط بالغلط (الحماية الفعلية إن الدالة للـ Admin بس). قبل ما الناس تشتغل بجد شغّل:
--   drop function public.reset_all_data(text);
-- =====================================================================

create or replace function public.reset_all_data(p_password text) returns jsonb
language plpgsql security definer set search_path = public as $$
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
  delete from public.stock_balances;
  delete from public.stock_ledger;
  delete from public.transfer_lines;
  delete from public.document_lines;
  delete from public.documents;
  delete from public.periods;
  delete from public.import_errors;
  delete from public.import_rows;
  delete from public.import_batches;
  delete from public.products;
  delete from public.audit_log;
  delete from public.purge_log;

  perform setval('public.doc_no_seq', 1, false);
  perform setval(pg_get_serial_sequence('public.stock_ledger', 'id'), 1, false);
  perform setval(pg_get_serial_sequence('public.audit_log', 'id'), 1, false);
  perform setval(pg_get_serial_sequence('public.purge_log', 'id'), 1, false);

  -- أثر واحد بس إن إعادة الضبط حصلت (ومين عملها)
  select email into v_email from public.profiles where user_id = auth.uid();
  insert into public.audit_log (user_id, user_email, table_name, row_id, action, old_data)
  values (auth.uid(), v_email, 'system', null, 'ADMIN_RESET_ALL', v);
  return v;
end $$;

-- ---------- Grants ----------
revoke execute on all functions in schema public from public, anon;
grant  execute on all functions in schema public to authenticated;
revoke execute on function
  public._post_document(uuid, text), public._post_closing(uuid, text, boolean), public._send_transfer(uuid, text),
  public._reverse_core(uuid, text), public._closing_variances(uuid), public._period_gate(uuid, date, text),
  public._import_validate(uuid, text), public._imp_err(uuid, int, text, text), public._assert_import_access(text, uuid),
  public._assert_product_manage(), public._new_doc_no(text), public.audit_row(), public.audit_block_changes(),
  public.attach_audit(regclass), public.handle_new_user(), public.protect_root_profile(), public.apply_ledger_to_balance(),
  public.block_ledger_changes(), public.block_posted_delete(), public.set_updated_at(),
  public._purging(), public._purge_check(date, date)
from authenticated;

-- =====================================================================
-- KMS batch 1 / 004 — Grants
-- الجداول: قراءة بس للـ authenticated (RLS بتحدد مين يشوف إيه).
-- الكتابة: من خلال الـ RPCs بس.
-- =====================================================================

revoke all on all tables    in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;

grant select on
  public.kitchens, public.pages, public.profiles, public.user_kitchens, public.user_pages,
  public.access_invites, public.audit_log, public.products,
  public.documents, public.document_lines, public.stock_ledger, public.stock_balances, public.periods,
  public.import_batches, public.import_rows, public.import_errors
to authenticated;

-- الـ RPCs: authenticated بس
revoke execute on all functions in schema public from public, anon;
grant  execute on all functions in schema public to authenticated;

-- دوال داخلية/Triggers: مش متاحة للمستخدم من الـ API
revoke execute on function
  public._post_document(uuid, text),
  public._import_validate(uuid, text),
  public._imp_err(uuid, int, text, text),
  public._assert_import_access(text, uuid),
  public._new_doc_no(text),
  public.audit_row(),
  public.audit_block_changes(),
  public.attach_audit(regclass),
  public.handle_new_user(),
  public.enforce_email_domain(),
  public.protect_root_profile(),
  public.apply_ledger_to_balance(),
  public.block_ledger_changes(),
  public.block_posted_delete(),
  public.set_updated_at()
from authenticated;

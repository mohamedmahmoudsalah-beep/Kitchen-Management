-- =====================================================================
-- KMS batch 5 / 011 — بحث + ترقيم صفحات لقوايم المستندات (من غير حد 500)
-- security invoker: الـ RLS بتتطبق على المستخدم زي أي Select عادي.
-- p_mode: 'own' = مستندات المطبخ، 'incoming' = تحويلات واردة للمطبخ (من غير Draft)
-- p_include_open: للتحويلات — أي تحويل لسه مفتوح (مستني استلام/مرتجع) يظهر حتى لو برا الفترة
-- p_reversals: يظهّر مستندات الـ Reversal كمان (قوايم المستندات العادية بتعرضها)
-- p_q: بيدوّر في Doc No / الملاحظة / كود أو اسم أي منتج في سطور المستند
-- =====================================================================
create index if not exists document_lines_doc_idx on public.document_lines (document_id);
create index if not exists documents_counterpart_idx on public.documents (counterpart_kitchen_id, doc_type, status)
  where counterpart_kitchen_id is not null;

create or replace function public.documents_search(
  p_type text, p_kitchen uuid, p_from date, p_to date, p_mode text default 'own', p_include_open boolean default false,
  p_q text default null, p_status text default null, p_limit int default 100, p_offset int default 0,
  p_reversals boolean default false
) returns table (
  id uuid, doc_no text, doc_type text, doc_date date, status text, note text, override_reason text,
  reverses_document_id uuid, created_at timestamptz, kitchen_id uuid, counterpart_kitchen_id uuid, lines_count bigint, total_count bigint
)
language plpgsql stable security invoker set search_path = public as $$
declare v_pat text;
begin
  if p_mode not in ('own', 'incoming') then raise exception 'mode غلط'; end if;
  p_limit := least(greatest(coalesce(p_limit, 100), 1), 1000);
  p_offset := greatest(coalesce(p_offset, 0), 0);
  v_pat := case when nullif(btrim(p_q), '') is null then null
                else '%' || replace(replace(replace(btrim(p_q), '\', '\\'), '%', '\%'), '_', '\_') || '%' end;
  return query
    select d.id, d.doc_no, d.doc_type, d.doc_date, d.status, d.note, d.override_reason, d.reverses_document_id, d.created_at,
           d.kitchen_id, d.counterpart_kitchen_id,
           (select count(*) from public.document_lines l where l.document_id = d.id) as lines_count,
           count(*) over () as total_count
      from public.documents d
     where d.doc_type = p_type
       and (p_reversals or d.reverses_document_id is null)
       and (case when p_mode = 'own' then d.kitchen_id = p_kitchen
                 else d.counterpart_kitchen_id = p_kitchen and d.status <> 'DRAFT' end)
       and ((d.doc_date between p_from and p_to) or (p_include_open and d.status in ('PENDING_RECEIPT', 'RETURN_PENDING')))
       and (p_status is null or p_status = '' or d.status = p_status)
       and (v_pat is null
            or d.doc_no ilike v_pat or coalesce(d.note, '') ilike v_pat
            or exists (select 1 from public.document_lines l join public.products pr on pr.id = l.product_id
                        where l.document_id = d.id
                          and (pr.syt_code ilike v_pat or coalesce(pr.generic_code, '') ilike v_pat or pr.name ilike v_pat)))
     order by d.doc_date desc, d.created_at desc
     limit p_limit offset p_offset;
end $$;

revoke execute on all functions in schema public from public, anon;
grant  execute on all functions in schema public to authenticated;
revoke execute on function
  public._post_document(uuid, text), public._post_closing(uuid, text, boolean), public._send_transfer(uuid, text),
  public._reverse_core(uuid, text), public._closing_variances(uuid), public._period_gate(uuid, date, text),
  public._import_validate(uuid, text), public._imp_err(uuid, int, text, text), public._assert_import_access(text, uuid),
  public._assert_product_manage(), public._new_doc_no(text), public.audit_row(), public.audit_block_changes(),
  public.attach_audit(regclass), public.handle_new_user(), public.protect_root_profile(), public.apply_ledger_to_balance(),
  public.block_ledger_changes(), public.block_posted_delete(), public.set_updated_at()
from authenticated;

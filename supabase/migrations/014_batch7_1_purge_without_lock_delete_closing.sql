-- =====================================================================
-- KMS batch 7.1 / 014
--  1) مسح الفترات القديمة: مبقاش لازم تكون مقفولة. الـ Admin بيقرر، والمسح بيقفل الفترة تلقائيًا لكل المطابخ بعد ما يخلص.
--  2) delete_closing(): مسح مستند جرد (Admin بس، حتى لو الفترة مقفولة) مع تسوية فروقه، والرصيد بيرجع زي ما كان.
-- =====================================================================

create or replace function public._purge_check(p_from date, p_to date) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_block text[] := '{}'; v_docs uuid[]; r record; n bigint;
begin
  select coalesce(array_agg(id), '{}') into v_docs from public.documents where doc_date between p_from and p_to;
  if cardinality(v_docs) = 0 then v_block := v_block || 'مفيش مستندات في الفترة دي'; end if;

  select count(*) into n from public.documents where id = any (v_docs)
     and doc_type = 'TRANSFER' and status in ('PENDING_RECEIPT', 'RETURN_PENDING');
  if n > 0 then v_block := v_block || format('فيه %s تحويل لسه مفتوح (مستني استلام أو مرتجع) في الفترة', n); end if;

  -- (الفترة مش لازم تكون مقفولة: الـ Admin بيقرر، والمسح بيقفل الفترة تلقائيًا بعد ما يخلص)

  -- حركات المستندات دي لازم كلها جوه الفترة (مفيش استلام/مرتجع بعد آخر الفترة)
  select count(*) into n from public.stock_ledger where document_id = any (v_docs) and posting_date not between p_from and p_to;
  if n > 0 then v_block := v_block || format('فيه %s حركة لمستندات الفترة تاريخها بره الفترة (تحويل اتستلم بعد آخر الفترة) — وسّع الفترة أو استنى', n); end if;

  -- مستندات باقية بتشاور على مستندات هتتمسح (Reverse/تسوية جرد)
  select count(*) into n from public.documents d
   where d.id <> all (v_docs) and (d.reverses_document_id = any (v_docs) or d.source_document_id = any (v_docs));
  if n > 0 then v_block := v_block || format('فيه %s مستند برا الفترة مرتبط بمستندات جواها (Reverse أو تسوية جرد) — وسّع الفترة', n); end if;

  -- التحويل بيجري: رصيد IN_TRANSIT / RETURN_PENDING لازم يكون صفر
  select count(*) into n from (
    select 1 from public.stock_ledger where document_id = any (v_docs) and location <> 'WAREHOUSE'
     group by kitchen_id, location, product_id having sum(qty_base) <> 0) x;
  if n > 0 then v_block := v_block || format('فيه %s صنف لسه في In transit / Return pending من مستندات الفترة', n); end if;

  return jsonb_build_object(
    'ok', cardinality(v_block) = 0,
    'blockers', to_jsonb(v_block),
    'counts', jsonb_build_object(
      'documents', cardinality(v_docs),
      'lines', (select count(*) from public.document_lines where document_id = any (v_docs)),
      'ledger', (select count(*) from public.stock_ledger where document_id = any (v_docs)),
      'audit', (select count(*) from public.audit_log where table_name = 'documents' and row_id = any (select id::text from unnest(v_docs) id)),
      'carry_rows', (select count(*) from (select 1 from public.stock_ledger where document_id = any (v_docs) and location = 'WAREHOUSE'
                                           group by kitchen_id, product_id having sum(qty_base) <> 0) c)));
end $$;

create or replace function public.purge_range(p_from date, p_to date, p_confirm text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_chk jsonb; v_docs uuid[]; v_counts jsonb; v_email text; r record; v_doc uuid; v_n int;
  v_audit bigint; v_batches bigint; v_bad bigint; v_run record; v_locked int := 0;
begin
  if not public.is_admin() then raise exception 'مسح الفترات للـ Admin بس'; end if;
  if p_from is null or p_to is null or p_from > p_to
     or p_from <> date_trunc('month', p_from)::date
     or p_to <> (date_trunc('month', p_to) + interval '1 month - 1 day')::date then
    raise exception 'المسح بشهور كاملة بس — من أول يوم في الشهر لآخر يوم في الشهر';
  end if;
  if p_to >= date_trunc('month', current_date)::date then raise exception 'مينفعش تمسح الشهر الحالي أو شهر لسه ما خلصش'; end if;
  if p_confirm is distinct from format('PURGE %s → %s', to_char(p_from, 'YYYY-MM'), to_char(p_to, 'YYYY-MM')) then
    raise exception 'التأكيد غلط — لازم تكتب: PURGE % → %', to_char(p_from, 'YYYY-MM'), to_char(p_to, 'YYYY-MM');
  end if;

  v_chk := public._purge_check(p_from, p_to);
  if not (v_chk ->> 'ok')::boolean then
    raise exception 'المسح متوقف: %', (select string_agg(x, ' | ') from jsonb_array_elements_text(v_chk -> 'blockers') x);
  end if;

  perform set_config('kms.purge', 'on', true);
  select coalesce(array_agg(id), '{}') into v_docs from public.documents where doc_date between p_from and p_to;

  create temp table _purge_nets on commit drop as
    select l.kitchen_id, l.product_id, sum(l.qty_base) as q
      from public.stock_ledger l where l.document_id = any (v_docs) and l.location = 'WAREHOUSE'
     group by l.kitchen_id, l.product_id having sum(l.qty_base) <> 0;

  delete from public.stock_ledger   where document_id = any (v_docs);
  delete from public.transfer_lines where document_id = any (v_docs);
  delete from public.document_lines where document_id = any (v_docs);
  delete from public.audit_log      where table_name = 'documents' and row_id = any (select id::text from unnest(v_docs) id);
  get diagnostics v_audit = row_count;
  delete from public.documents      where id = any (v_docs);

  -- مستند ترحيل واحد لكل مطبخ: الرصيد الصافي للفترة المحذوفة (بيتحسب كـ Opening في التقارير)
  for r in select distinct n.kitchen_id, k.code from _purge_nets n join public.kitchens k on k.id = n.kitchen_id loop
    insert into public.documents (doc_no, doc_type, kitchen_id, doc_date, status, note, created_by, posted_by, posted_at)
    values (format('ARC-%s-%s-%s', r.code, to_char(p_from, 'YYMM'), to_char(p_to, 'YYMM')), 'ADJUSTMENT', r.kitchen_id, p_to, 'POSTED',
            format('ARCHIVE carry-forward: مستندات %s → %s اتأرشفت واتمسحت، والرصيد الصافي اتحفظ هنا', p_from, p_to),
            auth.uid(), auth.uid(), now())
    returning id into v_doc;
    insert into public.document_lines (document_id, line_no, product_id, qty_input, input_mode, qty_pieces, qty_base, uom_factor_snapshot, unit_cost_snapshot, note)
      select v_doc, row_number() over (order by p.syt_code), n.product_id, n.q, 'BASE', round(n.q / nullif(p.uom_factor, 0), 4), n.q,
             p.uom_factor, p.cost_per_uom, 'ARCHIVE carry-forward'
        from _purge_nets n join public.products p on p.id = n.product_id where n.kitchen_id = r.kitchen_id;
    insert into public.stock_ledger (document_id, line_id, kitchen_id, location, product_id, movement_type, qty_base, unit_cost, posting_date)
      select v_doc, dl.id, r.kitchen_id, 'WAREHOUSE', dl.product_id, 'OPENING', dl.qty_base, coalesce(dl.unit_cost_snapshot, 0), p_to
        from public.document_lines dl where dl.document_id = v_doc;
  end loop;

  -- قفل الفترة تلقائيًا لكل المطابخ (عشان محدش يضيف حاجة جوه فترة اتمسحت): الأيام اللي لسه مش مقفولة بس
  update public.periods set status = 'CLOSED', closed_by = auth.uid(), closed_at = now(), reopen_reason = null
   where status = 'OPEN' and from_date >= p_from and to_date <= p_to;
  for r in select id from public.kitchens where is_active loop
    for v_run in
      select min(x.d) as f, max(x.d) as t from (
        select g.d::date as d, g.d::date - (row_number() over (order by g.d))::int as grp
          from generate_series(p_from, p_to, interval '1 day') g(d)
         where not public.is_period_closed(r.id, g.d::date)
           and not exists (select 1 from public.periods o where o.kitchen_id = r.id and g.d::date between o.from_date and o.to_date)) x
       group by x.grp
    loop
      insert into public.periods (kitchen_id, from_date, to_date, status, closed_by, closed_at)
      values (r.id, v_run.f, v_run.t, 'CLOSED', auth.uid(), now());
      v_locked := v_locked + 1;
    end loop;
  end loop;

  -- تنضيف سجل الـ Import القديم (اللي مفيش مستندات باقية ليه ومر عليه 30 يوم)
  delete from public.import_batches b
   where b.created_at < now() - interval '30 days'
     and not exists (select 1 from public.documents d where d.import_batch_id = b.id);
  get diagnostics v_batches = row_count;

  -- أمان أخير: الأرصدة لازم تفضل مطابقة للـ Ledger (لو فيه فرق، كل حاجة بترجع كأن شيء مجرّاش)
  select count(*) into v_bad from (
    select coalesce(l.kitchen_id, b.kitchen_id), coalesce(l.location, b.location), coalesce(l.product_id, b.product_id)
      from (select kitchen_id, location, product_id, sum(qty_base) q from public.stock_ledger group by 1, 2, 3) l
      full join public.stock_balances b using (kitchen_id, location, product_id)
     where coalesce(l.q, 0) <> coalesce(b.qty_base, 0)) x;
  if v_bad > 0 then raise exception 'فحص الأرصدة فشل بعد المسح (% صنف) — اتلغى المسح', v_bad; end if;

  v_counts := (v_chk -> 'counts') || jsonb_build_object('audit_deleted', v_audit, 'import_batches_deleted', v_batches, 'periods_locked', v_locked);
  select email into v_email from public.profiles where user_id = auth.uid();
  insert into public.purge_log (user_id, user_email, from_date, to_date, counts) values (auth.uid(), v_email, p_from, p_to, v_counts);
  return v_counts;
end $$;

-- ---------- مسح مستند جرد (Closing) — Admin بس، حتى لو الفترة مقفولة ----------
-- بيمسح الجرد + تسوية فروقه + أي Reverse مرتبط، وبيرجّع الرصيد زي ما كان قبل الجرد. بيتسجل في الـ Audit.
create or replace function public.delete_closing(p_doc uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  d public.documents%rowtype; v_set uuid[]; v_new uuid[]; v_email text; v_bad record; v_lines bigint;
begin
  if not public.is_admin() then raise exception 'مسح الجرد للـ Admin بس'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception 'سبب المسح مطلوب'; end if;
  select * into d from public.documents where id = p_doc for update;
  if not found then raise exception 'المستند مش موجود'; end if;
  if d.doc_type <> 'CLOSING' or d.reverses_document_id is not null then raise exception 'ده مش مستند جرد أصلي'; end if;

  v_set := array[d.id];
  loop
    select coalesce(array_agg(id), '{}') into v_new from public.documents
     where id <> all (v_set) and (source_document_id = any (v_set) or reverses_document_id = any (v_set));
    exit when cardinality(v_new) = 0;
    v_set := v_set || v_new;
  end loop;

  perform set_config('kms.purge', 'on', true);
  create temp table _dc_eff on commit drop as
    select kitchen_id, location, product_id, sum(qty_base) as q from public.stock_ledger
     where document_id = any (v_set) group by 1, 2, 3 having sum(qty_base) <> 0;

  select p.syt_code, b.qty_base as cur, e.q into v_bad
    from _dc_eff e join public.products p on p.id = e.product_id
    left join public.stock_balances b on b.kitchen_id = e.kitchen_id and b.location = e.location and b.product_id = e.product_id
   where coalesce(b.qty_base, 0) - e.q < 0 limit 1;
  if found then
    raise exception 'مسح الجرد هيخلي رصيد المنتج % سالب (الرصيد الحالي %، وتسوية الجرد %) — فيه حركات بعد الجرد اعتمدت عليه. اعمل Reverse للحركات دي الأول.', v_bad.syt_code, v_bad.cur, v_bad.q;
  end if;

  update public.stock_balances b set qty_base = b.qty_base - e.q
    from _dc_eff e where b.kitchen_id = e.kitchen_id and b.location = e.location and b.product_id = e.product_id;
  select count(*) into v_lines from public.document_lines where document_id = any (v_set);
  delete from public.stock_ledger   where document_id = any (v_set);
  delete from public.transfer_lines where document_id = any (v_set);
  delete from public.document_lines where document_id = any (v_set);
  delete from public.documents      where id = any (v_set);

  select email into v_email from public.profiles where user_id = auth.uid();
  insert into public.audit_log (user_id, user_email, table_name, row_id, action, kitchen_id, old_data, new_data)
  values (auth.uid(), v_email, 'documents', d.id::text, 'ADMIN_DELETE_CLOSING', d.kitchen_id,
          jsonb_build_object('closing', to_jsonb(d), 'documents_deleted', cardinality(v_set), 'lines_deleted', v_lines),
          jsonb_build_object('reason', p_reason));
  return jsonb_build_object('doc_no', d.doc_no, 'documents_deleted', cardinality(v_set), 'lines_deleted', v_lines);
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

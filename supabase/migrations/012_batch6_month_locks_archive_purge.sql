-- =====================================================================
-- KMS batch 6 / 012
--  1) قفل الفترات: شهور كاملة بس (من أول يوم في الشهر لآخر يوم في شهر تاني)
--  2) أرشفة ومسح فترة (Admin بس): بعد تنزيل الصفحات بيتمسح المستندات/السطور/الحركات/الـ Audit بتاعتها،
--     والرصيد بيتحفظ كمستند ترحيل واحد (ARC-…) لكل مطبخ — الأرصدة والتقارير للشهور الجديدة مبتتأثرش.
-- =====================================================================

-- ---------- 0) علم "المسح الجاري" (بيتظبط جوه purge_range بس، ولازم يكون المستخدم Admin) ----------
create or replace function public._purging() returns boolean
language sql stable as $$
  select coalesce(current_setting('kms.purge', true), '') = 'on' and public.is_admin()
$$;

create or replace function public.block_ledger_changes() returns trigger
language plpgsql as $$
begin
  if tg_op in ('UPDATE', 'DELETE') and public._purging() then
    if tg_op = 'DELETE' then return old; else return new; end if;
  end if;
  raise exception 'Stock Ledger append-only — اعمل حركة عكسية بدل التعديل أو الحذف';
end $$;

create or replace function public.block_posted_delete() returns trigger
language plpgsql as $$
declare v_status text;
begin
  if public._purging() then return old; end if;
  if tg_table_name = 'documents' then v_status := old.status;
  else select status into v_status from public.documents where id = old.document_id;
  end if;
  if v_status is distinct from 'DRAFT' then
    raise exception 'مينفعش حذف مستند اتعمله Post — استخدم Reverse';
  end if;
  return old;
end $$;

create or replace function public.audit_block_changes() returns trigger
language plpgsql as $$
begin
  if tg_op = 'DELETE' and public._purging() then return old; end if;
  raise exception 'Audit log append-only';
end $$;

create or replace function public.apply_ledger_to_balance() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if public._purging() then return null; end if;   -- صفوف الترحيل مبتتحسبش تاني على الأرصدة (الرصيد متحسب أصلًا)
  update public.stock_balances
     set qty_base = qty_base + new.qty_base
   where kitchen_id = new.kitchen_id and location = new.location and product_id = new.product_id;
  if not found then
    begin
      insert into public.stock_balances (kitchen_id, location, product_id, qty_base)
      values (new.kitchen_id, new.location, new.product_id, new.qty_base);
    exception when unique_violation then
      update public.stock_balances
         set qty_base = qty_base + new.qty_base
       where kitchen_id = new.kitchen_id and location = new.location and product_id = new.product_id;
    end;
  end if;
  return null;
end $$;

create or replace function public.audit_row() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_old jsonb; v_new jsonb; v_row jsonb; v_email text;
begin
  if public._purging() then return null; end if;   -- المسح مبيكتبش Audit لنفسه (بيتسجل في purge_log)
  if tg_op in ('UPDATE', 'DELETE') then v_old := to_jsonb(old); end if;
  if tg_op in ('INSERT', 'UPDATE') then v_new := to_jsonb(new); end if;
  v_row := coalesce(v_new, v_old);
  select email into v_email from public.profiles where user_id = auth.uid();
  insert into public.audit_log (user_id, user_email, table_name, row_id, action, kitchen_id, old_data, new_data)
  values (auth.uid(), v_email, tg_table_name,
          coalesce(v_row ->> 'id', v_row ->> 'user_id', v_row ->> 'email', v_row ->> 'key'),
          tg_op, nullif(v_row ->> 'kitchen_id', '')::uuid, v_old, v_new);
  return null;
end $$;

-- ---------- 1) قفل الفترات: شهور كاملة ----------
create or replace function public.close_period(p_kitchen uuid, p_from date, p_to date) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if not (public.my_role() in ('admin', 'manager') and public.has_kitchen(p_kitchen)) then
    raise exception 'قفل الفترة للـ Admin أو الـ Manager على مطابخه';
  end if;
  if p_from is null or p_to is null or p_from > p_to then raise exception 'الفترة غير صحيحة'; end if;
  if p_from <> date_trunc('month', p_from)::date
     or p_to <> (date_trunc('month', p_to) + interval '1 month - 1 day')::date then
    raise exception 'قفل الفترة بشهور كاملة بس — من أول يوم في الشهر لآخر يوم في الشهر';
  end if;
  insert into public.periods (kitchen_id, from_date, to_date, status, closed_by, closed_at)
  values (p_kitchen, p_from, p_to, 'CLOSED', auth.uid(), now())
  returning id into v_id;
  return v_id;
end $$;

-- ---------- 2) سجل المسح (بيفضل دايمًا، صغير) ----------
create table if not exists public.purge_log (
  id         bigserial primary key,
  at         timestamptz not null default now(),
  user_id    uuid,
  user_email text,
  from_date  date not null,
  to_date    date not null,
  counts     jsonb not null
);
alter table public.purge_log enable row level security;
revoke all on public.purge_log from anon, authenticated;
grant select on public.purge_log to authenticated;
drop policy if exists purge_log_read on public.purge_log;
create policy purge_log_read on public.purge_log for select to authenticated using (public.is_admin());

-- ---------- فحص قبل المسح (بيرجّع الموانع + الأعداد) ----------
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

  -- كل مطبخ ليه حركة في الفترة لازم تكون الفترة مقفولة عنده بالكامل
  for r in
    select k.id, k.name from public.kitchens k
     where k.id in (select kitchen_id from public.documents where id = any (v_docs)
                    union select kitchen_id from public.stock_ledger where document_id = any (v_docs))
  loop
    if exists (select 1 from generate_series(p_from, p_to, interval '1 day') g(d) where not public.is_period_closed(r.id, g.d::date)) then
      v_block := v_block || format('مطبخ %s: الفترة مش مقفولة بالكامل (اقفلها الأول من Period lock)', r.name);
    end if;
  end loop;

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

create or replace function public.purge_preview(p_from date, p_to date) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'مسح الفترات للـ Admin بس'; end if;
  return public._purge_check(p_from, p_to) || jsonb_build_object('from', p_from, 'to', p_to);
end $$;

-- ---------- المسح ----------
-- p_confirm لازم يساوي: PURGE yyyy-mm → yyyy-mm  (الشهر الأول → الشهر الأخير)
create or replace function public.purge_range(p_from date, p_to date, p_confirm text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_chk jsonb; v_docs uuid[]; v_counts jsonb; v_email text; r record; v_doc uuid; v_n int;
  v_audit bigint; v_batches bigint; v_bad bigint;
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

  v_counts := (v_chk -> 'counts') || jsonb_build_object('audit_deleted', v_audit, 'import_batches_deleted', v_batches);
  select email into v_email from public.profiles where user_id = auth.uid();
  insert into public.purge_log (user_id, user_email, from_date, to_date, counts) values (auth.uid(), v_email, p_from, p_to, v_counts);
  return v_counts;
end $$;

-- ---------- 3) رسائل وفحص الفترة المقفولة: مفيش حد (غير الـ Admin) يضيف/يعدّل/يمسح فيها، حتى كـ Draft ----------
create or replace function public._period_gate(p_kitchen uuid, p_date date, p_override text) returns text
language plpgsql security definer set search_path = public as $$
begin
  if public.is_period_closed(p_kitchen, p_date) then
    if not public.is_admin() then
      raise exception 'الفترة اللي فيها تاريخ % مقفولة (اتقفلت والرصيد اترحّل) — مينفعش أي إضافة أو تعديل أو مسح فيها. ارجع للـ Admin', p_date;
    end if;
    if coalesce(btrim(p_override), '') = '' then
      raise exception 'الفترة مقفولة — لازم سبب للتعديل (override reason)';
    end if;
    return p_override;
  end if;
  return null;
end $$;

create or replace function public.save_document(
  p_id uuid, p_type text, p_kitchen uuid, p_date date, p_note text, p_lines jsonb, p_counterpart uuid default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  d public.documents%rowtype;
  v_id uuid; e jsonb; i int := 0;
  pr public.products%rowtype; rs public.reasons%rowtype;
  v_qty numeric; v_mode text; v_base numeric; v_pieces numeric; v_dir text;
  v_reason text; v_reason_id uuid; v_seen uuid[] := '{}';
begin
  if p_id is not null then
    select * into d from public.documents where id = p_id for update;
    if not found then raise exception 'المستند مش موجود'; end if;
    if d.status <> 'DRAFT' then raise exception 'المستند % مش Draft — مينفعش يتعدّل', d.doc_no; end if;
    p_type := d.doc_type; p_kitchen := d.kitchen_id;
  end if;
  if p_type not in ('PURCHASE', 'WH_TXN', 'WASTE', 'ADJUSTMENT', 'TRANSFER', 'CLOSING') then
    raise exception 'نوع المستند % مش مدعوم للإدخال اليدوي', p_type;
  end if;
  if not (public.can_write_kitchen(p_kitchen) and public.has_page(public.doc_type_page(p_type))) then
    raise exception 'مش مسموحلك تدخل المستند ده للمطبخ ده';
  end if;
  if p_date is null then raise exception 'التاريخ مطلوب'; end if;
  if not public.is_admin() then
    if public.is_period_closed(p_kitchen, p_date) then
      raise exception 'الفترة اللي فيها تاريخ % مقفولة (اتقفلت والرصيد اترحّل) — مينفعش أي إضافة أو تعديل أو مسح فيها. ارجع للـ Admin', p_date;
    end if;
    if p_id is not null and public.is_period_closed(d.kitchen_id, d.doc_date) then
      raise exception 'الفترة اللي فيها تاريخ % مقفولة (اتقفلت والرصيد اترحّل) — مينفعش أي إضافة أو تعديل أو مسح فيها. ارجع للـ Admin', d.doc_date;
    end if;
  end if;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'أضف سطر واحد على الأقل';
  end if;
  if jsonb_array_length(p_lines) > 2000 then raise exception 'الحد الأقصى 2000 سطر في المستند'; end if;
  if p_type = 'TRANSFER' then
    if p_counterpart is null or p_counterpart = p_kitchen
       or not exists (select 1 from public.kitchens where id = p_counterpart and is_active) then
      raise exception 'اختار المطبخ المستلم (مختلف عن المرسل)';
    end if;
  else
    p_counterpart := null;
  end if;

  if p_id is null then
    insert into public.documents (doc_no, doc_type, kitchen_id, doc_date, status, counterpart_kitchen_id, note)
    values (public._new_doc_no(p_type), p_type, p_kitchen, p_date, 'DRAFT', p_counterpart, nullif(btrim(p_note), ''))
    returning id into v_id;
  else
    v_id := p_id;
    update public.documents set doc_date = p_date, note = nullif(btrim(p_note), ''), counterpart_kitchen_id = p_counterpart
     where id = v_id;
    delete from public.document_lines where document_id = v_id;
  end if;

  for e in select * from jsonb_array_elements(p_lines) loop
    i := i + 1;
    if coalesce(e ->> 'product_id', '') !~ '^[0-9a-fA-F-]{36}$' then raise exception 'سطر %: اختار المنتج', i; end if;
    select * into pr from public.products where id = (e ->> 'product_id')::uuid;
    if not found or not pr.is_active then raise exception 'سطر %: المنتج مش موجود أو غير Active', i; end if;

    v_mode := coalesce(nullif(e ->> 'mode', ''), 'BASE');
    if v_mode not in ('PIECE', 'BASE') then raise exception 'سطر %: وحدة الإدخال غلط', i; end if;
    v_qty := public.try_numeric(btrim(coalesce(e ->> 'qty', '')));
    if v_qty is null then raise exception 'سطر %: الكمية لازم تكون رقم', i; end if;
    if p_type = 'CLOSING' then
      if v_qty < 0 then raise exception 'سطر %: كمية الجرد لازم تكون صفر أو أكبر', i; end if;
      if pr.id = any (v_seen) then raise exception 'سطر %: المنتج % متكرر في الجرد', i, pr.syt_code; end if;
      v_seen := v_seen || pr.id;
    elsif v_qty <= 0 then
      raise exception 'سطر %: الكمية لازم تكون أكبر من صفر', i;
    end if;

    if v_mode = 'PIECE' then
      v_pieces := v_qty; v_base := round(v_qty * pr.uom_factor, 4);
    else
      v_base := v_qty; v_pieces := round(v_qty / pr.uom_factor, 4);
    end if;
    if v_base = 0 and p_type <> 'CLOSING' then raise exception 'سطر %: الكمية بتساوي صفر بعد التحويل', i; end if;

    v_reason := null; v_reason_id := null;
    if p_type in ('WASTE', 'ADJUSTMENT') then
      if coalesce(e ->> 'reason_id', '') !~ '^[0-9a-fA-F-]{36}$' then raise exception 'سطر %: اختار السبب', i; end if;
      select * into rs from public.reasons where id = (e ->> 'reason_id')::uuid and is_active;
      if not found then raise exception 'سطر %: السبب مش موجود أو متعطل', i; end if;
      v_reason := rs.name; v_reason_id := rs.id;
      if p_type = 'WASTE' and rs.direction = 'INCREASE' then
        raise exception 'سطر %: السبب "%" للزيادة بس — مينفعش في Waste', i, rs.name;
      end if;
      if p_type = 'ADJUSTMENT' then
        v_dir := coalesce(nullif(e ->> 'direction', ''), case rs.direction when 'INCREASE' then 'INCREASE' when 'DECREASE' then 'DECREASE' end);
        if v_dir is null or v_dir not in ('INCREASE', 'DECREASE') then raise exception 'سطر %: حدد زيادة ولا نقص', i; end if;
        if rs.direction <> 'ANY' and rs.direction <> v_dir then
          raise exception 'سطر %: السبب "%" اتجاهه % بس', i, rs.name, case rs.direction when 'INCREASE' then 'زيادة' else 'نقص' end;
        end if;
        if v_dir = 'DECREASE' then v_base := -v_base; v_pieces := -v_pieces; end if;
      end if;
    end if;

    insert into public.document_lines (document_id, line_no, product_id, qty_input, input_mode, qty_pieces, qty_base,
                                       uom_factor_snapshot, reason, reason_id, note)
    values (v_id, i, pr.id, v_qty, v_mode, v_pieces, v_base, pr.uom_factor, v_reason, v_reason_id,
            nullif(btrim(coalesce(e ->> 'note', '')), ''));
  end loop;
  return v_id;
end $$;

create or replace function public.delete_draft(p_doc uuid) returns void
language plpgsql security definer set search_path = public as $$
declare d public.documents%rowtype;
begin
  select * into d from public.documents where id = p_doc for update;
  if not found then raise exception 'المستند مش موجود'; end if;
  if d.status <> 'DRAFT' then raise exception 'مينفعش حذف مستند اتعمله Post — استخدم Reverse'; end if;
  if not (public.can_write_kitchen(d.kitchen_id) and public.has_page(public.doc_type_page(d.doc_type))) then
    raise exception 'مش مسموحلك';
  end if;
  if not public.is_admin() and public.is_period_closed(d.kitchen_id, d.doc_date) then
    raise exception 'الفترة اللي فيها تاريخ % مقفولة (اتقفلت والرصيد اترحّل) — مينفعش أي إضافة أو تعديل أو مسح فيها. ارجع للـ Admin', d.doc_date;
  end if;
  delete from public.document_lines where document_id = d.id;
  delete from public.documents where id = d.id;
end $$;

create or replace function public._post_document(p_doc uuid, p_override_reason text default null) returns void
language plpgsql security definer set search_path = public as $$
declare
  d       public.documents%rowtype;
  r       record;
  v_avail numeric;
begin
  select * into d from public.documents where id = p_doc for update;
  if not found then raise exception 'المستند مش موجود'; end if;
  if d.status <> 'DRAFT' then raise exception 'المستند % اتعمله Post قبل كده', d.doc_no; end if;
  if d.doc_type not in ('OPENING', 'PURCHASE', 'WH_TXN', 'WASTE', 'ADJUSTMENT') then
    raise exception 'نوع المستند % مش مدعوم في الـ Post العام', d.doc_type;
  end if;
  if not exists (select 1 from public.document_lines where document_id = d.id) then
    raise exception 'المستند فاضي';
  end if;

  if public.is_period_closed(d.kitchen_id, d.doc_date) then
    if not public.is_admin() then
      raise exception 'الفترة اللي فيها تاريخ % مقفولة (اتقفلت والرصيد اترحّل) — مينفعش أي إضافة أو تعديل أو مسح فيها. ارجع للـ Admin', d.doc_date;
    end if;
    if coalesce(btrim(p_override_reason), '') = '' then
      raise exception 'الفترة مقفولة — لازم سبب للتعديل (override reason)';
    end if;
    update public.documents set override_reason = p_override_reason where id = d.id;
  end if;

  update public.document_lines l set unit_cost_snapshot = p.cost_per_uom
    from public.products p where p.id = l.product_id and l.document_id = d.id;

  for r in
    select l.product_id, pr.syt_code,
           sum(case when d.doc_type in ('OPENING', 'PURCHASE', 'ADJUSTMENT') then l.qty_base else -l.qty_base end) as eff
      from public.document_lines l join public.products pr on pr.id = l.product_id
     where l.document_id = d.id
     group by l.product_id, pr.syt_code
    having sum(case when d.doc_type in ('OPENING', 'PURCHASE', 'ADJUSTMENT') then l.qty_base else -l.qty_base end) < 0
  loop
    select coalesce(qty_base, 0) into v_avail from public.stock_balances
     where kitchen_id = d.kitchen_id and location = 'WAREHOUSE' and product_id = r.product_id;
    if coalesce(v_avail, 0) + r.eff < 0 then
      raise exception 'رصيد غير كافٍ للمنتج % — المتاح % والمطلوب %', r.syt_code, coalesce(v_avail, 0), -r.eff;
    end if;
  end loop;

  insert into public.stock_ledger
    (document_id, line_id, kitchen_id, location, product_id, movement_type, qty_base, unit_cost, posting_date)
  select d.id, l.id, d.kitchen_id, 'WAREHOUSE', l.product_id,
         case d.doc_type
           when 'OPENING' then 'OPENING' when 'PURCHASE' then 'PURCHASE'
           when 'WH_TXN' then 'WH_TXN' when 'WASTE' then 'WASTE'
           when 'ADJUSTMENT' then case when l.qty_base > 0 then 'ADJ_PLUS' else 'ADJ_MINUS' end
         end,
         case when d.doc_type in ('OPENING', 'PURCHASE', 'ADJUSTMENT') then l.qty_base else -l.qty_base end,
         p.cost_per_uom, d.doc_date
    from public.document_lines l join public.products p on p.id = l.product_id
   where l.document_id = d.id and l.qty_base <> 0
   order by (case when d.doc_type in ('OPENING', 'PURCHASE', 'ADJUSTMENT') then l.qty_base else -l.qty_base end) < 0,
            l.line_no;

  update public.documents set status = 'POSTED', posted_by = auth.uid(), posted_at = now() where id = d.id;
end $$;

create or replace function public._reverse_core(p_doc uuid, p_reason text) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  d       public.documents%rowtype;
  c       record;
  v_new   uuid;
  v_ovr   text;
  r       record;
  v_avail numeric;
begin
  select * into d from public.documents where id = p_doc for update;
  if not found then raise exception 'المستند مش موجود'; end if;
  if d.reverses_document_id is not null
     or not ((d.doc_type <> 'TRANSFER' and d.status = 'POSTED') or (d.doc_type = 'TRANSFER' and d.status = 'PENDING_RECEIPT')) then
    raise exception 'المستند % مش قابل للـ Reverse (التحويل بعد الاستلام بيتقفل بالمرتجع مش بالـ Reverse)', d.doc_no;
  end if;

  if public.is_period_closed(d.kitchen_id, d.doc_date) then
    if not public.is_admin() then
      raise exception 'الفترة مقفولة (اتقفلت والرصيد اترحّل) — مينفعش Reverse فيها. ارجع للـ Admin';
    end if;
    v_ovr := p_reason;
  end if;

  if d.doc_type = 'CLOSING' then
    for c in select id from public.documents
              where source_document_id = d.id and status = 'POSTED' and reverses_document_id is null loop
      begin
        perform public._reverse_core(c.id, 'عكس تسوية الجرد: ' || p_reason);
      exception when others then
        raise exception 'مينفعش عكس الجرد لأن عكس تسوية فروقه فشل (%). راجع الأرصدة الحالية أو اعمل Adjustment يدوي.', sqlerrm;
      end;
    end loop;
  end if;

  for r in
    select l.kitchen_id, l.location, l.product_id, pr.syt_code, -sum(l.qty_base) as eff
      from public.stock_ledger l join public.products pr on pr.id = l.product_id
     where l.document_id = d.id
     group by l.kitchen_id, l.location, l.product_id, pr.syt_code
    having -sum(l.qty_base) < 0
  loop
    select coalesce(qty_base, 0) into v_avail from public.stock_balances
     where kitchen_id = r.kitchen_id and location = r.location and product_id = r.product_id;
    if coalesce(v_avail, 0) + r.eff < 0 then
      raise exception 'الرصيد الحالي للمنتج % (%) مش بيسمح بالـ Reverse — استخدم Stock Adjustment', r.syt_code, coalesce(v_avail, 0);
    end if;
  end loop;

  insert into public.documents (doc_no, doc_type, kitchen_id, doc_date, status, reverses_document_id,
                                counterpart_kitchen_id, note, override_reason, posted_by, posted_at)
  values (public._new_doc_no('REVERSAL'), d.doc_type, d.kitchen_id, d.doc_date, 'POSTED', d.id,
          d.counterpart_kitchen_id, 'Reversal of ' || d.doc_no || ': ' || p_reason, v_ovr, auth.uid(), now())
  returning id into v_new;

  insert into public.document_lines (document_id, line_no, product_id, qty_input, input_mode, qty_pieces,
                                     qty_base, uom_factor_snapshot, unit_cost_snapshot, reason, reason_id, note)
  select v_new, line_no, product_id, qty_input, input_mode, qty_pieces, qty_base,
         uom_factor_snapshot, unit_cost_snapshot, reason, reason_id, note
    from public.document_lines where document_id = d.id;

  insert into public.stock_ledger
    (document_id, line_id, kitchen_id, location, product_id, movement_type, qty_base, unit_cost, posting_date, is_reversal)
  select v_new, nl.id, l.kitchen_id, l.location, l.product_id, l.movement_type, -l.qty_base, l.unit_cost, d.doc_date, true
    from public.stock_ledger l
    join public.document_lines ol on ol.id = l.line_id
    join public.document_lines nl on nl.document_id = v_new and nl.line_no = ol.line_no
   where l.document_id = d.id
   order by (-l.qty_base) < 0, l.id;

  update public.documents set status = 'REVERSED' where id = d.id;
  return v_new;
end $$;

create or replace function public._import_validate(p_batch uuid, p_override text) returns int
language plpgsql security definer set search_path = public as $$
declare
  b        public.import_batches%rowtype;
  r        record;
  rs       public.reasons%rowtype;
  v_staged int;
  v_errs   int;
  v_ok     boolean;
  v_exists boolean;
  t_code text; t_date text; t_qty text; t_qp text; t_qb text; t_reason text; t_note text;
  t_syt text; t_gen text; t_name text; t_cat text; t_uomn text; t_factor text; t_cost text; t_cpu text;
  v_ids uuid[]; v_n int; pr public.products%rowtype;
  v_date date; v_num numeric; v_mode text; v_pieces numeric; v_base numeric;
  v_reason text; v_reason_id uuid;
  v_factor numeric; v_cost numeric; v_cpu numeric;
  v_cnt int; v_txt text; v_first_date date; t_to text; v_cp uuid;
begin
  select * into b from public.import_batches where id = p_batch for update;
  delete from public.import_errors where batch_id = p_batch;
  update public.import_rows set is_valid = false, product_id = null, doc_date = null, qty_input = null,
         input_mode = null, qty_pieces = null, qty_base = null, reason = null, reason_id = null,
         note = null, parsed = null, counterpart_id = null
   where batch_id = p_batch;

  select count(*) into v_staged from public.import_rows where batch_id = p_batch;
  if v_staged = 0 then
    perform public._imp_err(p_batch, 0, null, 'الملف فاضي');
  elsif v_staged <> b.total_rows then
    perform public._imp_err(p_batch, 0, null,
      format('عدد الصفوف اللي وصلت (%s) مختلف عن عدد صفوف الملف (%s) — أعد الرفع', v_staged, b.total_rows));
  end if;

  -- ===== Data Product =====
  if b.module = 'products' then
    for r in select row_no, raw from public.import_rows where batch_id = p_batch order by row_no loop
      v_ok := true;
      t_syt := nullif(btrim(r.raw ->> 'syt_code'), ''); t_gen := nullif(btrim(r.raw ->> 'generic_code'), '');
      t_name := nullif(btrim(r.raw ->> 'name'), ''); t_cat := nullif(btrim(r.raw ->> 'category'), '');
      t_uomn := nullif(btrim(r.raw ->> 'uom_name'), ''); t_factor := nullif(btrim(r.raw ->> 'factor'), '');
      t_cost := nullif(btrim(r.raw ->> 'cost'), ''); t_cpu := nullif(btrim(r.raw ->> 'cost_per_uom'), '');
      v_factor := null; v_cost := null; v_cpu := null; v_exists := false;

      if t_syt is null then
        perform public._imp_err(p_batch, r.row_no, 'Syt Code', 'Syt Code مطلوب'); v_ok := false;
      else
        v_exists := exists (select 1 from public.products where syt_code = t_syt);
        if b.mode = 'insert' and v_exists then
          perform public._imp_err(p_batch, r.row_no, 'Syt Code', format('Syt Code %s موجود بالفعل — استخدم Update from file أو Import (إضافة وتحديث)', t_syt)); v_ok := false;
        elsif b.mode = 'update' and not v_exists then
          perform public._imp_err(p_batch, r.row_no, 'Syt Code', format('Syt Code %s مش موجود — استخدم Import لإضافته', t_syt)); v_ok := false;
        end if;
        if not v_exists and t_name is null then
          perform public._imp_err(p_batch, r.row_no, 'Product Name', 'اسم المنتج مطلوب للمنتج الجديد'); v_ok := false;
        end if;
      end if;
      if t_factor is not null then
        v_factor := public.try_numeric(t_factor);
        if v_factor is null or v_factor <= 0 then
          perform public._imp_err(p_batch, r.row_no, 'Base Qty per Syt', format('لازم يكون رقم > 0 (القيمة: %s)', t_factor)); v_ok := false;
        end if;
      end if;
      if t_cost is not null then
        v_cost := public.try_numeric(t_cost);
        if v_cost is null or v_cost < 0 then
          perform public._imp_err(p_batch, r.row_no, 'Cost', format('Cost لازم يكون رقم ≥ 0 (القيمة: %s)', t_cost)); v_ok := false;
        end if;
      end if;
      if t_cpu is not null then
        v_cpu := public.try_numeric(t_cpu);
        if v_cpu is null or v_cpu < 0 then
          perform public._imp_err(p_batch, r.row_no, 'Cost Pr UOM', format('Cost Pr UOM لازم يكون رقم ≥ 0 (القيمة: %s)', t_cpu)); v_ok := false;
        end if;
      end if;
      if v_ok then
        update public.import_rows set is_valid = true,
          parsed = jsonb_build_object('syt_code', t_syt, 'generic_code', t_gen, 'name', t_name, 'uom_name', t_uomn,
                                      'category', t_cat, 'factor', v_factor, 'cost', v_cost, 'cost_per_uom', v_cpu)
         where batch_id = p_batch and row_no = r.row_no;
      end if;
    end loop;

    for r in
      select row_no, first_row, syt from (
        select row_no, parsed ->> 'syt_code' as syt,
               first_value(row_no) over (partition by parsed ->> 'syt_code' order by row_no) as first_row
          from public.import_rows where batch_id = p_batch and is_valid) s
       where row_no <> first_row
    loop
      perform public._imp_err(p_batch, r.row_no, 'Syt Code',
        format('Syt Code %s مكرر في الملف (أول ظهور في صف %s)', r.syt, r.first_row));
      update public.import_rows set is_valid = false where batch_id = p_batch and row_no = r.row_no;
    end loop;

  -- ===== حركات المخزون =====
  else
    for r in select row_no, raw from public.import_rows where batch_id = p_batch order by row_no loop
      v_ok := true;
      t_code := nullif(btrim(r.raw ->> 'code'), ''); t_date := nullif(btrim(r.raw ->> 'date'), '');
      t_qty := nullif(btrim(r.raw ->> 'qty'), ''); t_qp := nullif(btrim(r.raw ->> 'qty_pieces'), '');
      t_qb := nullif(btrim(r.raw ->> 'qty_base'), '');
      t_reason := nullif(btrim(r.raw ->> 'reason'), ''); t_note := nullif(btrim(r.raw ->> 'note'), '');
      pr := null; v_date := null; v_num := null; v_reason := null; v_reason_id := null; rs := null;
      t_to := nullif(btrim(r.raw ->> 'to'), ''); v_cp := null;

      if t_date is null then
        perform public._imp_err(p_batch, r.row_no, 'Date', 'التاريخ مطلوب'); v_ok := false;
      else
        v_date := public.try_date(t_date);
        if v_date is null then
          perform public._imp_err(p_batch, r.row_no, 'Date', format('تاريخ غير صالح (%s) — المتوقع yyyy-mm-dd', t_date)); v_ok := false;
        end if;
      end if;

      if t_code is null then
        perform public._imp_err(p_batch, r.row_no, 'Code', 'الكود مطلوب'); v_ok := false;
      else
        select array_agg(id order by syt_code) into v_ids
          from public.products where syt_code = t_code or generic_code = t_code;
        v_n := coalesce(cardinality(v_ids), 0);
        if v_n = 0 then
          perform public._imp_err(p_batch, r.row_no, 'Code', format('الكود %s مش موجود في Data Product', t_code)); v_ok := false;
        elsif v_n > 1 then
          select string_agg(syt_code, ', ') into v_txt
            from (select syt_code from public.products where id = any (v_ids) order by syt_code limit 5) s;
          perform public._imp_err(p_batch, r.row_no, 'Code',
            format('الكود %s بيطابق %s منتجات (Syt: %s) — استخدم Syt Code', t_code, v_n, v_txt)); v_ok := false;
        else
          select * into pr from public.products where id = v_ids[1];
          if not pr.is_active then
            perform public._imp_err(p_batch, r.row_no, 'Code', format('المنتج %s غير Active', pr.syt_code)); v_ok := false;
          end if;
        end if;
      end if;

      v_cnt := (t_qty is not null)::int + (t_qp is not null)::int + (t_qb is not null)::int;
      if v_cnt = 0 then
        perform public._imp_err(p_batch, r.row_no, 'Qty', 'الكمية مطلوبة'); v_ok := false;
      elsif v_cnt > 1 then
        perform public._imp_err(p_batch, r.row_no, 'Qty', 'أكتر من عمود كمية ممتلئ في نفس الصف'); v_ok := false;
      else
        v_txt := coalesce(t_qp, t_qb, t_qty);
        v_mode := case when t_qp is not null then 'PIECE' when t_qb is not null then 'BASE' else b.qty_mode end;
        v_num := public.try_numeric(v_txt);
        if v_num is null then
          perform public._imp_err(p_batch, r.row_no, 'Qty', format('الكمية لازم تكون رقم (القيمة: %s)', v_txt)); v_ok := false;
        elsif b.module = 'closing' and v_num < 0 then
          perform public._imp_err(p_batch, r.row_no, 'Qty', 'كمية الجرد لازم تكون صفر أو أكبر'); v_ok := false;
        elsif b.module = 'opening' and v_num < 0 then
          perform public._imp_err(p_batch, r.row_no, 'Qty', 'الرصيد الافتتاحي لازم يكون صفر أو أكبر'); v_ok := false;
        elsif b.module not in ('adjustments', 'closing', 'opening') and v_num < 0 then
          perform public._imp_err(p_batch, r.row_no, 'Qty', 'الكمية لازم تكون صفر أو أكبر'); v_ok := false;
        end if;
      end if;

      if v_ok then
        if v_mode = 'PIECE' then
          v_pieces := v_num; v_base := round(v_num * pr.uom_factor, 4);
        else
          v_base := v_num; v_pieces := round(v_num / pr.uom_factor, 4);
        end if;
        if v_base = 0 and v_num <> 0 then
          perform public._imp_err(p_batch, r.row_no, 'Qty', 'الكمية بالوحدة الأساسية بتساوي صفر بعد التحويل'); v_ok := false;
        end if;
      end if;

      -- السبب من القايمة المشتركة: إجباري في Adjustments، واختياري في Waste (لكن لو اتكتب لازم يكون صح)
      if b.module in ('adjustments', 'waste') then
        if t_reason is null then
          perform public._imp_err(p_batch, r.row_no, 'Reason', 'Reason مطلوب — اختار من قايمة الأسباب'); v_ok := false;
        else
          select * into rs from public.reasons where lower(btrim(name)) = lower(t_reason) and is_active;
          if not found then
            perform public._imp_err(p_batch, r.row_no, 'Reason',
              format('السبب "%s" مش في القايمة — ضيفه من زرار Add reason الأول', t_reason)); v_ok := false;
          else
            v_reason := rs.name; v_reason_id := rs.id;
            if b.module = 'waste' and rs.direction = 'INCREASE' then
              perform public._imp_err(p_batch, r.row_no, 'Reason', format('السبب "%s" للزيادة بس — مينفعش في Waste', rs.name)); v_ok := false;
            elsif b.module = 'adjustments' and v_num is not null then
              if rs.direction = 'INCREASE' and v_num < 0 then
                perform public._imp_err(p_batch, r.row_no, 'Qty', format('"%s" سبب زيادة — الكمية لازم تكون موجبة', rs.name)); v_ok := false;
              elsif rs.direction = 'DECREASE' and v_num > 0 then
                perform public._imp_err(p_batch, r.row_no, 'Qty', format('"%s" سبب نقص — الكمية لازم تكون سالبة', rs.name)); v_ok := false;
              end if;
            end if;
          end if;
        end if;
      end if;

      if b.module = 'transfers' then
        if t_to is null then
          perform public._imp_err(p_batch, r.row_no, 'To', 'المطبخ المستلم (To) مطلوب'); v_ok := false;
        else
          select id into v_cp from public.kitchens
           where is_active and (lower(btrim(name)) = lower(t_to) or lower(code) = lower(t_to) or lower(replace(code, '_', ' ')) = lower(t_to));
          if v_cp is null then
            perform public._imp_err(p_batch, r.row_no, 'To', format('المطبخ المستلم "%s" مش معروف — اكتب اسم المطبخ زي ما هو (Plus Mall / Rehab / Maadi / NC7)', t_to)); v_ok := false;
          elsif v_cp = b.kitchen_id then
            perform public._imp_err(p_batch, r.row_no, 'To', 'المطبخ المستلم لازم يكون غير المرسل'); v_ok := false;
          end if;
        end if;
      end if;

      if v_ok then
        update public.import_rows set is_valid = true, product_id = pr.id, doc_date = v_date,
               qty_input = v_num, input_mode = v_mode, qty_pieces = v_pieces, qty_base = v_base,
               reason = v_reason, reason_id = v_reason_id, note = t_note, counterpart_id = v_cp
         where batch_id = p_batch and row_no = r.row_no;
      end if;
    end loop;

    if b.module = 'opening' then
      if exists (select 1 from public.documents where kitchen_id = b.kitchen_id and doc_type = 'OPENING'
                    and status = 'POSTED' and reverses_document_id is null) then
        perform public._imp_err(p_batch, 0, null, 'فيه رصيد افتتاحي متسجل بالفعل للمطبخ ده — اعمل Reverse له الأول');
      end if;
      select min(doc_date) into v_first_date from public.import_rows where batch_id = p_batch and is_valid;
      for r in select row_no, doc_date from public.import_rows
                where batch_id = p_batch and is_valid and doc_date <> v_first_date loop
        perform public._imp_err(p_batch, r.row_no, 'Date',
          format('الرصيد الافتتاحي لازم يكون بتاريخ واحد (%s) والصف ده تاريخه %s', v_first_date, r.doc_date));
        update public.import_rows set is_valid = false where batch_id = p_batch and row_no = r.row_no;
      end loop;
      for r in
        select row_no, first_row from (
          select row_no, first_value(row_no) over (partition by product_id order by row_no) as first_row
            from public.import_rows where batch_id = p_batch and is_valid) s
         where row_no <> first_row
      loop
        perform public._imp_err(p_batch, r.row_no, 'Code', format('المنتج متكرر في الرصيد الافتتاحي (أول ظهور في صف %s)', r.first_row));
        update public.import_rows set is_valid = false where batch_id = p_batch and row_no = r.row_no;
      end loop;
    end if;

    if b.module = 'closing' then
      select min(doc_date) into v_first_date from public.import_rows where batch_id = p_batch and is_valid;
      if v_first_date is not null and exists (select 1 from public.documents where kitchen_id = b.kitchen_id and doc_type = 'CLOSING'
                    and doc_date = v_first_date and status = 'POSTED' and reverses_document_id is null) then
        perform public._imp_err(p_batch, 0, null, format('فيه جرد متسجل بالفعل للمطبخ ده بتاريخ %s — اعمل Reverse له الأول', v_first_date));
      end if;
      for r in select row_no, doc_date from public.import_rows
                where batch_id = p_batch and is_valid and doc_date <> v_first_date loop
        perform public._imp_err(p_batch, r.row_no, 'Date',
          format('الجرد لازم يكون بتاريخ واحد (%s) والصف ده تاريخه %s', v_first_date, r.doc_date));
        update public.import_rows set is_valid = false where batch_id = p_batch and row_no = r.row_no;
      end loop;
      for r in
        select row_no, first_row from (
          select row_no, first_value(row_no) over (partition by product_id order by row_no) as first_row
            from public.import_rows where batch_id = p_batch and is_valid) s
         where row_no <> first_row
      loop
        perform public._imp_err(p_batch, r.row_no, 'Code', format('المنتج متكرر في الجرد (أول ظهور في صف %s)', r.first_row));
        update public.import_rows set is_valid = false where batch_id = p_batch and row_no = r.row_no;
      end loop;
    end if;

    for r in
      select ir.row_no, ir.doc_date from public.import_rows ir
       where ir.batch_id = p_batch and ir.is_valid and public.is_period_closed(b.kitchen_id, ir.doc_date)
    loop
      if not public.is_admin() then
        perform public._imp_err(p_batch, r.row_no, 'Date', format('الفترة اللي فيها %s مقفولة (اتقفلت والرصيد اترحّل) — مينفعش أي إضافة فيها. ارجع للـ Admin', r.doc_date));
        update public.import_rows set is_valid = false where batch_id = p_batch and row_no = r.row_no;
      elsif coalesce(btrim(p_override), '') = '' then
        perform public._imp_err(p_batch, r.row_no, 'Date', format('الفترة اللي فيها %s مقفولة — اكتب سبب التعديل (override reason)', r.doc_date));
        update public.import_rows set is_valid = false where batch_id = p_batch and row_no = r.row_no;
      end if;
    end loop;

    if b.module <> 'closing' then
    for r in
      with e as (
        select row_no, product_id, doc_date,
               case when b.module in ('waste', 'wh_txn', 'transfers') then -qty_base else qty_base end as eff
          from public.import_rows where batch_id = p_batch and is_valid),
      d as (
        select product_id, doc_date, sum(eff) as day_eff, min(row_no) filter (where eff < 0) as first_neg
          from e group by product_id, doc_date),
      c as (
        select product_id, doc_date, first_neg, sum(day_eff) over (partition by product_id order by doc_date) as cum
          from d),
      f as (
        select c.product_id, c.first_neg, coalesce(sb.qty_base, 0) as avail, c.cum,
               row_number() over (partition by c.product_id order by c.doc_date) as rn
          from c left join public.stock_balances sb
            on sb.kitchen_id = b.kitchen_id and sb.location = 'WAREHOUSE' and sb.product_id = c.product_id
         where coalesce(sb.qty_base, 0) + c.cum < 0)
      select f.first_neg, f.avail, f.cum, p.syt_code from f join public.products p on p.id = f.product_id
       where f.rn = 1 and f.first_neg is not null
    loop
      perform public._imp_err(p_batch, r.first_neg, 'Qty',
        format('رصيد غير كافٍ للمنتج %s — المتاح %s وصافي الخروج في الملف لحد التاريخ ده يتجاوزه بـ %s',
               r.syt_code, r.avail, -(r.avail + r.cum)));
      update public.import_rows set is_valid = false where batch_id = p_batch and row_no = r.first_neg;
    end loop;
    end if;
  end if;

  select count(*) into v_errs from public.import_errors where batch_id = p_batch;
  update public.import_batches
     set status = case when v_errs = 0 then 'validated' else 'failed' end,
         error_count = v_errs, override_reason = p_override
   where id = p_batch;
  return v_errs;
end $$;

-- ---------- 4) Product Card: الحركات بالترتيب الزمني (التاريخ ثم وقت التسجيل) والرصيد بعد كل حركة بنفس الترتيب ----------
create or replace function public.product_card(p_product uuid, p_kitchen uuid default null, p_from date default null, p_to date default null)
returns table (
  posting_date date, at timestamptz, doc_no text, doc_type text, doc_status text, kitchen text, counterpart text,
  location text, movement_type text, is_reversal boolean, qty_base numeric, qty_pieces numeric, uom_factor numeric,
  unit_cost numeric, value numeric, balance_after numeric, reason text, note text, user_email text
)
language plpgsql stable security definer set search_path = public as $$
begin
  if not (public.is_admin() or (public.my_role() = 'manager' and public.has_page('audit_log'))) then
    raise exception 'Product Card للـ Admin أو الـ Manager (بصفحة Audit Log) بس';
  end if;
  if p_product is null then raise exception 'اختار المنتج'; end if;

  return query
  with led as (
    select l.id, l.posting_date as pd, l.created_at as ts, l.document_id, l.line_id, l.kitchen_id, l.location as loc,
           l.movement_type as mt, l.is_reversal as rev, l.qty_base as q, l.unit_cost as uc, l.created_by,
           case when l.location = 'WAREHOUSE'
                then sum(l.qty_base) over (partition by l.kitchen_id, l.location order by l.posting_date, l.id) end as bal
      from public.stock_ledger l
     where l.product_id = p_product
       and (public.is_admin() or public.has_kitchen(l.kitchen_id))
  ),
  moves as (
    select x.pd, x.ts, d.doc_no, d.doc_type, d.status as dstatus, k.name as kname, ck.name as cname,
           x.loc, x.mt, x.rev, x.q, round(x.q / nullif(pr.uom_factor, 0), 4) as pcs, pr.uom_factor as f,
           x.uc, round(x.q * x.uc, 2) as val, x.bal, dl.reason as rsn,
           nullif(concat_ws(' | ', dl.note, d.note), '') as nt, coalesce(pf.email, x.created_by::text) as who
      from led x
      join public.documents d on d.id = x.document_id
      join public.kitchens k on k.id = x.kitchen_id
      left join public.kitchens ck on ck.id = d.counterpart_kitchen_id
      left join public.document_lines dl on dl.id = x.line_id
      join public.products pr on pr.id = p_product
      left join public.profiles pf on pf.user_id = x.created_by
     where (p_kitchen is null or x.kitchen_id = p_kitchen)
  ),
  counts as (  -- الجرد snapshot: مش حركة، بس بيظهر في الكارت (الكمية = الكمية المجرودة)
    select d.doc_date as pd, d.posted_at as ts, d.doc_no, d.doc_type, d.status as dstatus, k.name as kname, null::text as cname,
           'WAREHOUSE'::text as loc, 'CLOSING_COUNT'::text as mt, (d.reverses_document_id is not null) as rev,
           dl.qty_base as q, round(dl.qty_base / nullif(pr.uom_factor, 0), 4) as pcs, pr.uom_factor as f,
           dl.unit_cost_snapshot as uc, round(dl.qty_base * coalesce(dl.unit_cost_snapshot, 0), 2) as val,
           null::numeric as bal, dl.reason as rsn, nullif(concat_ws(' | ', dl.note, d.note), '') as nt,
           coalesce(pf.email, d.posted_by::text) as who
      from public.document_lines dl
      join public.documents d on d.id = dl.document_id
      join public.kitchens k on k.id = d.kitchen_id
      join public.products pr on pr.id = dl.product_id
      left join public.profiles pf on pf.user_id = d.posted_by
     where dl.product_id = p_product and d.doc_type = 'CLOSING' and d.status in ('POSTED', 'REVERSED')
       and (public.is_admin() or public.has_kitchen(d.kitchen_id))
       and (p_kitchen is null or d.kitchen_id = p_kitchen)
  )
  select u.pd, u.ts, u.doc_no, u.doc_type, u.dstatus, u.kname, u.cname, u.loc, u.mt, u.rev, u.q, u.pcs, u.f, u.uc, u.val, u.bal,
         u.rsn, u.nt, u.who
    from (select * from moves union all select * from counts) u
   where (p_from is null or u.pd >= p_from) and (p_to is null or u.pd <= p_to)
   order by u.pd, u.ts, (u.mt = 'CLOSING_COUNT');
end $$;

-- ---------- 5) آخر حجم (Syt Code) اتشترى لكل Generic Code — بيستخدمه الـ Import لما الكود يطابق أكتر من حجم ----------
create or replace function public.last_purchased_syt(p_codes text[]) returns table (code text, syt_code text, last_date date)
language sql stable security invoker set search_path = public as $$
  select distinct on (g.code) g.code, pr.syt_code, d.doc_date
    from unnest(p_codes) g(code)
    join public.products pr on pr.generic_code = g.code and pr.is_active
    join public.document_lines l on l.product_id = pr.id
    join public.documents d on d.id = l.document_id
   where d.doc_type = 'PURCHASE' and d.status = 'POSTED' and d.reverses_document_id is null
   order by g.code, d.doc_date desc, d.created_at desc
$$;

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

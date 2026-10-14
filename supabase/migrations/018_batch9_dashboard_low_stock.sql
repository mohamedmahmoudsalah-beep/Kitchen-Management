-- =====================================================================
-- KMS batch 9 / 018 — Dashboard كامل (All Kitchens + رسومات بالأيام) + صفحة Low Stock
--  1) صفحة جديدة low_stock (بتتدّي للمستخدمين من Access Control؛ الـ Admin بيشوفها تلقائي)
--  2) stock_levels: حدّ Low وحدّ High لكل صنف في كل مطبخ (بالوحدة الأساسية). الصنف = Generic Code لو موجود، وإلا Syt Code
--     الحالة: الرصيد <= Low → LOW | الرصيد >= High → HIGH | غير كده → AVG | مفيش حدود → NOT_SET
--  3) stock_levels_import: فحص كامل (غلطة واحدة = ولا صف يتحفظ، الأخطاء برقم الصف) ثم حفظ
--  4) report_low_stock: الرصيد الحالي (لايف، من غير تواريخ) + الحالة
--  5) dashboard_summary: p_kitchen = null يعني كل مطابخي، + أرقام جديدة. dashboard_trend: قيم بالأيام
--  6) reset_all_data بتمسح stock_levels كمان
-- =====================================================================

insert into public.pages (key, title, sort) values ('low_stock', 'Low Stock', 16) on conflict (key) do nothing;

-- ---------- الحدود ----------
create table public.stock_levels (
  id         uuid primary key default gen_random_uuid(),
  kitchen_id uuid not null references public.kitchens (id),
  item_key   text not null,                                   -- Generic Code لو موجود، وإلا Syt Code
  low_qty    numeric(18, 4) not null check (low_qty >= 0),
  high_qty   numeric(18, 4) not null,
  updated_at timestamptz not null default now(),
  updated_by uuid default auth.uid(),
  unique (kitchen_id, item_key),
  check (high_qty > low_qty)
);
create trigger stock_levels_updated before update on public.stock_levels
  for each row execute function public.set_updated_at();
select public.attach_audit('public.stock_levels');

alter table public.stock_levels enable row level security;
create policy stock_levels_read on public.stock_levels for select to authenticated
  using (public.has_kitchen(kitchen_id) and public.has_page('low_stock'));
revoke all on public.stock_levels from anon, authenticated;
grant select on public.stock_levels to authenticated;

-- ---------- رفع الحدود ----------
-- p_rows = [{row, code, low, high}] (الأرقام كنص بعد التطبيع من الواجهة). p_mode: 'upsert' (إضافة وتحديث) أو 'replace' (استبدال الكل)
-- p_commit = false → فحص بس. بيرجّع {ok, errors[], error_count, count, created, updated, unchanged, removed}
create function public.stock_levels_import(p_kitchen uuid, p_rows jsonb, p_mode text, p_commit boolean)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  r record; v_key text; v_prev int; v_errs jsonb := '[]'::jsonb; v_en int := 0;
  v_seen jsonb := '{}'::jsonb; v_ok jsonb := '[]'::jsonb; v_low numeric; v_high numeric;
  v_created int := 0; v_updated int := 0; v_unchanged int := 0; v_removed int := 0; v_ex record;
begin
  if not (public.can_write_kitchen(p_kitchen) and public.has_page('low_stock')) then
    raise exception 'مش مسموحلك ترفع Low Stock للمطبخ ده';
  end if;
  if p_mode not in ('upsert', 'replace') then raise exception 'الوضع غلط'; end if;
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then
    raise exception 'الملف مفيهوش صفوف';
  end if;

  for r in select coalesce((e ->> 'row')::int, 0) as row_no, nullif(btrim(e ->> 'code'), '') as code,
                  nullif(btrim(e ->> 'low'), '') as low_s, nullif(btrim(e ->> 'high'), '') as high_s
             from jsonb_array_elements(p_rows) e
  loop
    v_key := null; v_low := null; v_high := null;
    if r.code is null then
      v_en := v_en + 1; if v_en <= 200 then v_errs := v_errs || jsonb_build_object('row', r.row_no, 'column', 'Code', 'reason', 'الكود فاضي'); end if;
      continue;
    end if;

    -- الأولوية: Syt Code المطابق تمامًا، وبعدين Generic Code
    select coalesce(nullif(btrim(p.generic_code), ''), p.syt_code) into v_key
      from public.products p where lower(btrim(p.syt_code)) = lower(r.code) limit 1;
    if v_key is null then
      select btrim(p.generic_code) into v_key
        from public.products p where lower(btrim(p.generic_code)) = lower(r.code) order by p.syt_code limit 1;
    end if;
    if v_key is null then
      v_en := v_en + 1; if v_en <= 200 then v_errs := v_errs || jsonb_build_object('row', r.row_no, 'column', 'Code', 'reason', 'الكود مش موجود في Data Product: ' || r.code); end if;
      continue;
    end if;

    if r.low_s is null or r.low_s !~ '^[0-9]+(\.[0-9]+)?$' then
      v_en := v_en + 1; if v_en <= 200 then v_errs := v_errs || jsonb_build_object('row', r.row_no, 'column', 'Low Stock', 'reason', 'Low Stock لازم يكون رقم صفر أو أكبر'); end if;
      continue;
    end if;
    if r.high_s is null or r.high_s !~ '^[0-9]+(\.[0-9]+)?$' then
      v_en := v_en + 1; if v_en <= 200 then v_errs := v_errs || jsonb_build_object('row', r.row_no, 'column', 'High Stock', 'reason', 'High Stock لازم يكون رقم'); end if;
      continue;
    end if;
    v_low := r.low_s::numeric; v_high := r.high_s::numeric;
    if v_high <= v_low then
      v_en := v_en + 1; if v_en <= 200 then v_errs := v_errs || jsonb_build_object('row', r.row_no, 'column', 'High Stock', 'reason', 'High Stock لازم يكون أكبر من Low Stock'); end if;
      continue;
    end if;
    if v_seen ? lower(v_key) then
      v_prev := (v_seen ->> lower(v_key))::int;
      v_en := v_en + 1; if v_en <= 200 then v_errs := v_errs || jsonb_build_object('row', r.row_no, 'column', 'Code', 'reason', 'الصنف ده متكرر (نفس الـ Generic Code) — موجود في صف ' || v_prev); end if;
      continue;
    end if;
    v_seen := v_seen || jsonb_build_object(lower(v_key), r.row_no);
    v_ok := v_ok || jsonb_build_object('key', v_key, 'low', v_low, 'high', v_high);
  end loop;

  if v_en > 0 then
    return jsonb_build_object('ok', false, 'errors', v_errs, 'error_count', v_en);
  end if;

  -- إحصائيات (للفحص والحفظ)
  for v_ex in select o ->> 'key' as k, (o ->> 'low')::numeric as l, (o ->> 'high')::numeric as h from jsonb_array_elements(v_ok) o loop
    if not exists (select 1 from public.stock_levels s where s.kitchen_id = p_kitchen and s.item_key = v_ex.k) then v_created := v_created + 1;
    elsif exists (select 1 from public.stock_levels s where s.kitchen_id = p_kitchen and s.item_key = v_ex.k and s.low_qty = v_ex.l and s.high_qty = v_ex.h) then v_unchanged := v_unchanged + 1;
    else v_updated := v_updated + 1;
    end if;
  end loop;
  if p_mode = 'replace' then
    select count(*) into v_removed from public.stock_levels s
     where s.kitchen_id = p_kitchen and not exists (select 1 from jsonb_array_elements(v_ok) o where o ->> 'key' = s.item_key);
  end if;

  if p_commit then
    if p_mode = 'replace' then
      delete from public.stock_levels s
       where s.kitchen_id = p_kitchen and not exists (select 1 from jsonb_array_elements(v_ok) o where o ->> 'key' = s.item_key);
    end if;
    insert into public.stock_levels as t (kitchen_id, item_key, low_qty, high_qty)
    select p_kitchen, o ->> 'key', (o ->> 'low')::numeric, (o ->> 'high')::numeric from jsonb_array_elements(v_ok) o
    on conflict (kitchen_id, item_key) do update set low_qty = excluded.low_qty, high_qty = excluded.high_qty
      where (t.low_qty, t.high_qty) is distinct from (excluded.low_qty, excluded.high_qty);
  end if;

  return jsonb_build_object('ok', true, 'committed', p_commit, 'count', jsonb_array_length(v_ok),
    'created', v_created, 'updated', v_updated, 'unchanged', v_unchanged, 'removed', v_removed);
end $$;

-- ---------- تقرير Low Stock (داخلي: لعدة مطابخ) ----------
create function public._low_stock_rows(p_kitchens uuid[])
returns table (kitchen_id uuid, item_key text, product_name text, category text, sizes int,
               qty numeric, value numeric, low_qty numeric, high_qty numeric, status text)
language sql stable security definer set search_path = public as $$
  with prod as (
    select p.id, p.syt_code, p.name, p.category, p.cost_per_uom,
           coalesce(nullif(btrim(p.generic_code), ''), p.syt_code) as ik
      from public.products p),
  bal as (
    select b.kitchen_id, pr.ik, sum(b.qty_base) as qty, sum(b.qty_base * pr.cost_per_uom) as val,
           count(*) filter (where b.qty_base > 0) as sizes
      from public.stock_balances b join prod pr on pr.id = b.product_id
     where b.kitchen_id = any (p_kitchens) and b.location = 'WAREHOUSE'
     group by b.kitchen_id, pr.ik),
  lp as (
    select l.product_id, max(l.posting_date) as d from public.stock_ledger l
     where l.kitchen_id = any (p_kitchens) and l.movement_type = 'PURCHASE' group by l.product_id),
  rep as (     -- الاسم من آخر حجم اتشترى، وإلا أول Syt Code
    select distinct on (pr.ik) pr.ik, pr.name, pr.category
      from prod pr left join lp on lp.product_id = pr.id
     order by pr.ik, lp.d desc nulls last, pr.syt_code),
  lv as (select s.kitchen_id, s.item_key, s.low_qty, s.high_qty from public.stock_levels s where s.kitchen_id = any (p_kitchens))
  select coalesce(bal.kitchen_id, lv.kitchen_id), coalesce(bal.ik, lv.item_key), coalesce(rep.name, coalesce(bal.ik, lv.item_key)), rep.category,
         coalesce(bal.sizes, 0)::int, coalesce(bal.qty, 0), coalesce(bal.val, 0), lv.low_qty, lv.high_qty,
         case when lv.item_key is null then 'NOT_SET'
              when coalesce(bal.qty, 0) <= lv.low_qty then 'LOW'
              when coalesce(bal.qty, 0) >= lv.high_qty then 'HIGH'
              else 'AVG' end
    from bal full join lv on lv.kitchen_id = bal.kitchen_id and lv.item_key = bal.ik
    left join rep on rep.ik = coalesce(bal.ik, lv.item_key)
   where lv.item_key is not null or coalesce(bal.qty, 0) > 0
$$;

create function public.report_low_stock(p_kitchen uuid)
returns table (item_key text, product_name text, category text, sizes int, qty numeric, value numeric,
               low_qty numeric, high_qty numeric, status text)
language plpgsql stable security definer set search_path = public as $$
begin
  if not (public.has_kitchen(p_kitchen) and public.has_page('low_stock')) then
    raise exception 'مش مسموحلك تشوف Low Stock للمطبخ ده';
  end if;
  return query
    select s.item_key, s.product_name, s.category, s.sizes, s.qty, s.value, s.low_qty, s.high_qty, s.status
      from public._low_stock_rows(array[p_kitchen]) s
     order by case s.status when 'LOW' then 1 when 'AVG' then 2 when 'HIGH' then 3 else 4 end, s.item_key;
end $$;

-- ---------- Dashboard: p_kitchen = null يعني كل المطابخ المتاحة للمستخدم ----------
create or replace function public.dashboard_summary(p_kitchen uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_ids uuid[]; v_res jsonb; v_low jsonb;
begin
  if not public.has_page('dashboard') then raise exception 'مش مسموحلك تشوف Dashboard'; end if;
  if p_kitchen is null then
    select array_agg(k.id order by k.name) into v_ids from public.kitchens k where k.is_active and public.has_kitchen(k.id);
    if v_ids is null then raise exception 'مفيش مطابخ متاحة ليك'; end if;
  else
    if not public.has_kitchen(p_kitchen) then raise exception 'مش مسموحلك تشوف Dashboard للمطبخ ده'; end if;
    v_ids := array[p_kitchen];
  end if;

  if public.has_page('low_stock') then
    select jsonb_build_object(
      'low', count(*) filter (where status = 'LOW'), 'avg', count(*) filter (where status = 'AVG'),
      'high', count(*) filter (where status = 'HIGH'), 'not_set', count(*) filter (where status = 'NOT_SET'))
      into v_low from public._low_stock_rows(v_ids);
  end if;

  select jsonb_build_object(
    'kitchens_count', array_length(v_ids, 1),
    'stock_value', coalesce((select sum(b.qty_base * p.cost_per_uom) from public.stock_balances b join public.products p on p.id = b.product_id
                              where b.kitchen_id = any (v_ids) and b.location = 'WAREHOUSE'), 0),
    'products_in_stock', (select count(distinct b.product_id) from public.stock_balances b where b.kitchen_id = any (v_ids) and b.location = 'WAREHOUSE' and b.qty_base > 0),
    'in_transit_value', coalesce((select sum(b.qty_base * p.cost_per_uom) from public.stock_balances b join public.products p on p.id = b.product_id
                                   where b.kitchen_id = any (v_ids) and b.location = 'IN_TRANSIT'), 0),
    'return_pending_value', coalesce((select sum(b.qty_base * p.cost_per_uom) from public.stock_balances b join public.products p on p.id = b.product_id
                                       where b.kitchen_id = any (v_ids) and b.location = 'RETURN_PENDING'), 0),
    'incoming_to_confirm', (select count(*) from public.documents where doc_type = 'TRANSFER' and counterpart_kitchen_id = any (v_ids)
                             and status = 'PENDING_RECEIPT' and reverses_document_id is null),
    'outgoing_pending', (select count(*) from public.documents where doc_type = 'TRANSFER' and kitchen_id = any (v_ids)
                          and status = 'PENDING_RECEIPT' and reverses_document_id is null),
    'returns_to_confirm', (select count(*) from public.documents where doc_type = 'TRANSFER' and kitchen_id = any (v_ids)
                            and status = 'RETURN_PENDING' and reverses_document_id is null),
    'drafts', (select count(*) from public.documents where kitchen_id = any (v_ids) and status = 'DRAFT'),
    'last_closing', (select max(doc_date) from public.documents where kitchen_id = any (v_ids) and doc_type = 'CLOSING'
                       and status = 'POSTED' and reverses_document_id is null),
    'kitchens_without_closing', (select count(*) from unnest(v_ids) k where not exists (
                       select 1 from public.documents d where d.kitchen_id = k and d.doc_type = 'CLOSING' and d.status = 'POSTED' and d.reverses_document_id is null)),
    'locked_through', (select max(to_date) from public.periods where kitchen_id = any (v_ids) and status = 'CLOSED'),
    'cost_warnings', (select count(*) from public.products where cost_mismatch and is_active),
    'pending_users', case when public.my_role() in ('admin', 'manager') then (select count(*) from public.profiles where not is_active and role in ('viewer', 'kitchen_user')) else null end,
    'low_stock', v_low,
    'top_products', coalesce((select jsonb_agg(t) from (
        select p.syt_code, p.name as product_name, sum(b.qty_base) as qty, p.uom_factor, round(sum(b.qty_base * p.cost_per_uom), 2) as value
          from public.stock_balances b join public.products p on p.id = b.product_id
         where b.kitchen_id = any (v_ids) and b.location = 'WAREHOUSE' and b.qty_base > 0
         group by p.id, p.syt_code, p.name, p.uom_factor
         order by sum(b.qty_base * p.cost_per_uom) desc limit 8) t), '[]'::jsonb),
    'by_category', coalesce((select jsonb_agg(t) from (
        select coalesce(nullif(btrim(p.category), ''), 'Uncategorized') as category, round(sum(b.qty_base * p.cost_per_uom), 2) as value
          from public.stock_balances b join public.products p on p.id = b.product_id
         where b.kitchen_id = any (v_ids) and b.location = 'WAREHOUSE' and b.qty_base > 0
         group by 1 order by sum(b.qty_base * p.cost_per_uom) desc limit 8) t), '[]'::jsonb),
    'by_kitchen', coalesce((select jsonb_agg(t) from (
        select k.name, round(coalesce(sum(b.qty_base * p.cost_per_uom), 0), 2) as value
          from public.kitchens k
          left join public.stock_balances b on b.kitchen_id = k.id and b.location = 'WAREHOUSE'
          left join public.products p on p.id = b.product_id
         where k.id = any (v_ids) group by k.id, k.name order by 2 desc) t), '[]'::jsonb)
  ) into v_res;
  return v_res;
end $$;

-- قيم يومية (بسعر التكلفة الحالي): رصيد آخر اليوم، صرف المخزن (Warehouse Transactions)، الهالك، المشتريات
create function public.dashboard_trend(p_kitchen uuid, p_from date, p_to date)
returns table (day date, stock_value numeric, usage_value numeric, waste_value numeric, purchases_value numeric)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
declare v_ids uuid[]; v_base numeric;
begin
  if not public.has_page('dashboard') then raise exception 'مش مسموحلك تشوف Dashboard'; end if;
  if p_from is null or p_to is null or p_from > p_to then raise exception 'الفترة غير صحيحة'; end if;
  if p_to - p_from > 179 then raise exception 'الفترة أطول من 180 يوم'; end if;
  if p_kitchen is null then
    select array_agg(k.id) into v_ids from public.kitchens k where k.is_active and public.has_kitchen(k.id);
    if v_ids is null then raise exception 'مفيش مطابخ متاحة ليك'; end if;
  else
    if not public.has_kitchen(p_kitchen) then raise exception 'مش مسموحلك تشوف Dashboard للمطبخ ده'; end if;
    v_ids := array[p_kitchen];
  end if;

  select coalesce(sum(l.qty_base * p.cost_per_uom), 0) into v_base
    from public.stock_ledger l join public.products p on p.id = l.product_id
   where l.kitchen_id = any (v_ids) and l.location = 'WAREHOUSE' and l.posting_date < p_from;

  return query
  with d as (
    select l.posting_date as pd,
           sum(l.qty_base * p.cost_per_uom) as net,
           sum(case when l.movement_type = 'WH_TXN' then - l.qty_base * p.cost_per_uom else 0 end) as usage_v,
           sum(case when l.movement_type = 'WASTE' then - l.qty_base * p.cost_per_uom else 0 end) as waste_v,
           sum(case when l.movement_type = 'PURCHASE' then l.qty_base * p.cost_per_uom else 0 end) as purch_v
      from public.stock_ledger l join public.products p on p.id = l.product_id
     where l.kitchen_id = any (v_ids) and l.location = 'WAREHOUSE' and l.posting_date between p_from and p_to
     group by l.posting_date)
  select g.day,
         round(v_base + sum(coalesce(d.net, 0)) over (order by g.day), 2),
         round(coalesce(d.usage_v, 0), 2), round(coalesce(d.waste_v, 0), 2), round(coalesce(d.purch_v, 0), 2)
    from (select x::date as day from generate_series(p_from::timestamp, p_to::timestamp, interval '1 day') x) g
    left join d on d.pd = g.day
   order by g.day;
end $$;

-- ---------- reset_all_data: بتمسح stock_levels كمان (نفس 017 + سطر واحد) ----------
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
    'audit_log', (select count(*) from public.audit_log), 'purge_log', (select count(*) from public.purge_log),
    'stock_levels', (select count(*) from public.stock_levels));

  perform set_config('kms.purge', 'on', true);
  delete from public.stock_levels where true;
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

  select email into v_email from public.profiles where user_id = auth.uid();
  insert into public.audit_log (user_id, user_email, table_name, row_id, action, old_data)
  values (auth.uid(), v_email, 'system', null, 'ADMIN_RESET_ALL', v);
  return v;
end $$;

-- ---------- Grants ----------
revoke execute on function public.stock_levels_import(uuid, jsonb, text, boolean), public.report_low_stock(uuid),
  public.dashboard_trend(uuid, date, date), public._low_stock_rows(uuid[]) from public, anon;
grant execute on function public.stock_levels_import(uuid, jsonb, text, boolean), public.report_low_stock(uuid),
  public.dashboard_trend(uuid, date, date) to authenticated;
revoke execute on function public._low_stock_rows(uuid[]) from authenticated;

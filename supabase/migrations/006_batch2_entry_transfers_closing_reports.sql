-- =====================================================================
-- KMS batch 2 / 006
--  1) الإدخال اليدوي: Draft -> Post (Purchases / Warehouse Transactions / Waste / Adjustments / Closing)
--  2) Kitchens Transfer: Send -> In Transit -> Receive (الكمية الفعلية) -> Return Pending -> Closed
--  3) Closing / Stock Count (snapshot جرد، مش حركة في الـ Ledger) + Import لـ Closing
--  4) التقارير (بتتحسب من الـ Ledger مرة واحدة): Warehouse Stock و Consumption
--  5) Waste: السبب بقى إجباري (زي Adjustments)
-- =====================================================================

-- ---------- schema ----------
alter table public.stock_ledger drop constraint if exists stock_ledger_movement_type_check;
alter table public.stock_ledger add constraint stock_ledger_movement_type_check check (movement_type in
  ('OPENING', 'PURCHASE', 'TRANSFER_OUT', 'TRANSFER_IN', 'TRANSFER_RETURN_IN', 'WH_TXN', 'WASTE', 'ADJ_PLUS', 'ADJ_MINUS',
   'TRANSIT_IN', 'TRANSIT_OUT', 'RETURN_HOLD_IN', 'RETURN_HOLD_OUT'));

-- الجرد ممكن يكون صفر، فمينفعش qty_base <> 0 على مستوى الجدول (بتتفحص في الـ RPCs)
alter table public.document_lines drop constraint if exists document_lines_qty_base_check;

alter table public.documents add column received_by uuid;
alter table public.documents add column received_at timestamptz;
create unique index documents_one_closing on public.documents (kitchen_id, doc_date)
  where doc_type = 'CLOSING' and status = 'POSTED' and reverses_document_id is null;

create table public.transfer_lines (
  line_id        uuid primary key references public.document_lines (id),
  document_id    uuid not null references public.documents (id),
  sent_base      numeric(18, 4) not null check (sent_base > 0),
  received_base  numeric(18, 4) check (received_base >= 0 and received_base <= sent_base),
  returned_base  numeric(18, 4) not null default 0 check (returned_base >= 0),
  check (returned_base <= sent_base - coalesce(received_base, sent_base))
);
create index transfer_lines_doc_idx on public.transfer_lines (document_id);
alter table public.transfer_lines enable row level security;
create policy transfer_lines_read on public.transfer_lines for select to authenticated
  using (exists (select 1 from public.documents d where d.id = document_id));

-- المستلم يشوف التحويلات الموجهة لمطبخه (بس مش الـ Draft بتاع المرسل)
drop policy documents_read on public.documents;
create policy documents_read on public.documents for select to authenticated using (
  (public.has_kitchen(kitchen_id)
     or (counterpart_kitchen_id is not null and status <> 'DRAFT' and public.has_kitchen(counterpart_kitchen_id)))
  and public.has_page(public.doc_type_page(doc_type)));

-- ---------- helpers ----------
create function public._period_gate(p_kitchen uuid, p_date date, p_override text) returns text
language plpgsql security definer set search_path = public as $$
begin
  if public.is_period_closed(p_kitchen, p_date) then
    if not public.is_admin() then
      raise exception 'الفترة اللي فيها تاريخ % مقفولة — الإدخال بتاريخ رجعي للـ Admin بس', p_date;
    end if;
    if coalesce(btrim(p_override), '') = '' then
      raise exception 'الفترة مقفولة — لازم سبب للتعديل (override reason)';
    end if;
    return p_override;
  end if;
  return null;
end $$;

-- ---------- Draft: إنشاء / تعديل ----------
create function public.save_document(
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

create function public.delete_draft(p_doc uuid) returns void
language plpgsql security definer set search_path = public as $$
declare d public.documents%rowtype;
begin
  select * into d from public.documents where id = p_doc for update;
  if not found then raise exception 'المستند مش موجود'; end if;
  if d.status <> 'DRAFT' then raise exception 'مينفعش حذف مستند اتعمله Post — استخدم Reverse'; end if;
  if not (public.can_write_kitchen(d.kitchen_id) and public.has_page(public.doc_type_page(d.doc_type))) then
    raise exception 'مش مسموحلك';
  end if;
  delete from public.document_lines where document_id = d.id;
  delete from public.documents where id = d.id;
end $$;

-- ---------- Closing: Post (snapshot — مفيش حركة في الـ Ledger) ----------
create function public._post_closing(p_doc uuid, p_override text default null) returns void
language plpgsql security definer set search_path = public as $$
declare d public.documents%rowtype; v_ovr text;
begin
  select * into d from public.documents where id = p_doc for update;
  if not found then raise exception 'المستند مش موجود'; end if;
  if d.doc_type <> 'CLOSING' or d.status <> 'DRAFT' then raise exception 'مستند الجرد لازم يكون Draft'; end if;
  if not exists (select 1 from public.document_lines where document_id = d.id) then raise exception 'المستند فاضي'; end if;
  v_ovr := public._period_gate(d.kitchen_id, d.doc_date, p_override);
  if v_ovr is not null then update public.documents set override_reason = v_ovr where id = d.id; end if;
  update public.document_lines l set unit_cost_snapshot = p.cost_per_uom
    from public.products p where p.id = l.product_id and l.document_id = d.id;
  update public.documents set status = 'POSTED', posted_by = auth.uid(), posted_at = now() where id = d.id;
end $$;

-- ---------- Transfer: Send (المرسل) ----------
create function public._send_transfer(p_doc uuid, p_override text default null) returns void
language plpgsql security definer set search_path = public as $$
declare d public.documents%rowtype; v_ovr text; r record; v_avail numeric;
begin
  select * into d from public.documents where id = p_doc for update;
  if not found then raise exception 'المستند مش موجود'; end if;
  if d.doc_type <> 'TRANSFER' or d.status <> 'DRAFT' then raise exception 'التحويل لازم يكون Draft'; end if;
  if d.counterpart_kitchen_id is null or d.counterpart_kitchen_id = d.kitchen_id then
    raise exception 'اختار المطبخ المستلم';
  end if;
  if not exists (select 1 from public.document_lines where document_id = d.id) then raise exception 'المستند فاضي'; end if;
  v_ovr := public._period_gate(d.kitchen_id, d.doc_date, p_override);
  if v_ovr is not null then update public.documents set override_reason = v_ovr where id = d.id; end if;

  update public.document_lines l set unit_cost_snapshot = p.cost_per_uom
    from public.products p where p.id = l.product_id and l.document_id = d.id;

  for r in
    select l.product_id, pr.syt_code, sum(l.qty_base) as q
      from public.document_lines l join public.products pr on pr.id = l.product_id
     where l.document_id = d.id group by l.product_id, pr.syt_code
  loop
    select coalesce(qty_base, 0) into v_avail from public.stock_balances
     where kitchen_id = d.kitchen_id and location = 'WAREHOUSE' and product_id = r.product_id;
    if coalesce(v_avail, 0) < r.q then
      raise exception 'رصيد غير كافٍ للمنتج % — المتاح % والمطلوب تحويله %', r.syt_code, coalesce(v_avail, 0), r.q;
    end if;
  end loop;

  insert into public.transfer_lines (line_id, document_id, sent_base)
    select id, document_id, qty_base from public.document_lines where document_id = d.id;

  insert into public.stock_ledger (document_id, line_id, kitchen_id, location, product_id, movement_type, qty_base, unit_cost, posting_date)
    select d.id, l.id, d.kitchen_id, 'WAREHOUSE', l.product_id, 'TRANSFER_OUT', -l.qty_base, l.unit_cost_snapshot, d.doc_date
      from public.document_lines l where l.document_id = d.id;
  insert into public.stock_ledger (document_id, line_id, kitchen_id, location, product_id, movement_type, qty_base, unit_cost, posting_date)
    select d.id, l.id, d.kitchen_id, 'IN_TRANSIT', l.product_id, 'TRANSIT_IN', l.qty_base, l.unit_cost_snapshot, d.doc_date
      from public.document_lines l where l.document_id = d.id;

  update public.documents set status = 'PENDING_RECEIPT', posted_by = auth.uid(), posted_at = now() where id = d.id;
end $$;

-- Post موحّد (بيوزّع حسب النوع)
create or replace function public.post_document(p_doc uuid, p_override_reason text default null) returns void
language plpgsql security definer set search_path = public as $$
declare d public.documents%rowtype;
begin
  select * into d from public.documents where id = p_doc;
  if not found then raise exception 'المستند مش موجود'; end if;
  if not (public.can_write_kitchen(d.kitchen_id) and public.has_page(public.doc_type_page(d.doc_type))) then
    raise exception 'مش مسموحلك تعمل Post للمستند ده';
  end if;
  if d.doc_type = 'CLOSING' then perform public._post_closing(p_doc, p_override_reason);
  elsif d.doc_type = 'TRANSFER' then perform public._send_transfer(p_doc, p_override_reason);
  else perform public._post_document(p_doc, p_override_reason);
  end if;
end $$;

-- ---------- Transfer: Receive (المستلم يأكد الكمية الفعلية) ----------
-- p_lines: [{line_id, qty, mode: 'BASE'|'PIECE'}] — لازم كل سطر (ولو صفر)
create function public.receive_transfer(p_doc uuid, p_lines jsonb, p_date date default current_date, p_override text default null)
returns void
language plpgsql security definer set search_path = public as $$
declare
  d public.documents%rowtype; v_ovr text; tl record; e jsonb; v_found boolean;
  v_mode text; v_qty numeric; v_r numeric; v_s numeric; v_cnt int := 0; v_short boolean := false;
begin
  select * into d from public.documents where id = p_doc for update;
  if not found or d.doc_type <> 'TRANSFER' then raise exception 'التحويل مش موجود'; end if;
  if d.status <> 'PENDING_RECEIPT' then raise exception 'التحويل % مش في انتظار الاستلام (الحالة: %)', d.doc_no, d.status; end if;
  if not (public.can_write_kitchen(d.counterpart_kitchen_id) and public.has_page('kitchens_transfer')) then
    raise exception 'تأكيد الاستلام للمطبخ المستلم بس';
  end if;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' then raise exception 'سطور الاستلام غلط'; end if;
  v_ovr := public._period_gate(d.counterpart_kitchen_id, p_date, p_override);
  if v_ovr is not null then update public.documents set override_reason = coalesce(override_reason || ' | ', '') || v_ovr where id = d.id; end if;

  for tl in
    select t.line_id, t.sent_base, l.line_no, l.product_id, l.uom_factor_snapshot, l.unit_cost_snapshot
      from public.transfer_lines t join public.document_lines l on l.id = t.line_id
     where t.document_id = d.id order by l.line_no
  loop
    v_found := false;
    for e in select * from jsonb_array_elements(p_lines) loop
      if e ->> 'line_id' = tl.line_id::text then v_found := true; exit; end if;
    end loop;
    if not v_found then raise exception 'سطر %: لازم تحدد الكمية المستلمة (ولو صفر)', tl.line_no; end if;
    v_cnt := v_cnt + 1;

    v_mode := coalesce(nullif(e ->> 'mode', ''), 'BASE');
    v_qty := public.try_numeric(btrim(coalesce(e ->> 'qty', '')));
    if v_mode not in ('PIECE', 'BASE') or v_qty is null or v_qty < 0 then
      raise exception 'سطر %: الكمية المستلمة لازم تكون رقم صفر أو أكبر', tl.line_no;
    end if;
    v_r := case when v_mode = 'PIECE' then round(v_qty * tl.uom_factor_snapshot, 4) else round(v_qty, 4) end;
    if v_r > tl.sent_base then
      raise exception 'سطر %: المستلم (%) أكبر من المرسل (%)', tl.line_no, v_r, tl.sent_base;
    end if;
    v_s := tl.sent_base - v_r;

    update public.transfer_lines set received_base = v_r where line_id = tl.line_id;

    if v_r > 0 then
      insert into public.stock_ledger (document_id, line_id, kitchen_id, location, product_id, movement_type, qty_base, unit_cost, posting_date)
      values (d.id, tl.line_id, d.kitchen_id, 'IN_TRANSIT', tl.product_id, 'TRANSIT_OUT', -v_r, tl.unit_cost_snapshot, p_date),
             (d.id, tl.line_id, d.counterpart_kitchen_id, 'WAREHOUSE', tl.product_id, 'TRANSFER_IN', v_r, tl.unit_cost_snapshot, p_date);
    end if;
    if v_s > 0 then
      v_short := true;
      insert into public.stock_ledger (document_id, line_id, kitchen_id, location, product_id, movement_type, qty_base, unit_cost, posting_date)
      values (d.id, tl.line_id, d.kitchen_id, 'IN_TRANSIT', tl.product_id, 'TRANSIT_OUT', -v_s, tl.unit_cost_snapshot, p_date),
             (d.id, tl.line_id, d.kitchen_id, 'RETURN_PENDING', tl.product_id, 'RETURN_HOLD_IN', v_s, tl.unit_cost_snapshot, p_date);
    end if;
  end loop;

  if v_cnt <> jsonb_array_length(p_lines) then raise exception 'فيه سطور في الطلب مش تابعة للتحويل ده أو متكررة'; end if;

  update public.documents set status = case when v_short then 'RETURN_PENDING' else 'COMPLETED' end,
         received_by = auth.uid(), received_at = now() where id = d.id;
end $$;

-- ---------- Transfer: Confirm Return (المرسل يأكد استلام المرتجع) ----------
-- p_lines: [{line_id, qty, mode}] — ممكن على دفعات؛ التحويل بيتقفل CLOSED_PARTIAL لما كل المرتجع يرجع
create function public.confirm_return(p_doc uuid, p_lines jsonb, p_date date default current_date, p_override text default null)
returns void
language plpgsql security definer set search_path = public as $$
declare
  d public.documents%rowtype; v_ovr text; e jsonb; tl record;
  v_mode text; v_qty numeric; v_c numeric; v_pending numeric; v_total numeric := 0;
begin
  select * into d from public.documents where id = p_doc for update;
  if not found or d.doc_type <> 'TRANSFER' then raise exception 'التحويل مش موجود'; end if;
  if d.status <> 'RETURN_PENDING' then raise exception 'التحويل % مفيهوش مرتجع معلق (الحالة: %)', d.doc_no, d.status; end if;
  if not (public.can_write_kitchen(d.kitchen_id) and public.has_page('kitchens_transfer')) then
    raise exception 'تأكيد المرتجع للمطبخ المرسل بس';
  end if;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'اكتب كمية المرتجع';
  end if;
  v_ovr := public._period_gate(d.kitchen_id, p_date, p_override);
  if v_ovr is not null then update public.documents set override_reason = coalesce(override_reason || ' | ', '') || v_ovr where id = d.id; end if;

  for e in select * from jsonb_array_elements(p_lines) loop
    select t.line_id, t.sent_base, t.received_base, t.returned_base, l.line_no, l.product_id, l.uom_factor_snapshot, l.unit_cost_snapshot
      into tl
      from public.transfer_lines t join public.document_lines l on l.id = t.line_id
     where t.document_id = d.id and t.line_id::text = (e ->> 'line_id');
    if not found then raise exception 'سطر مش تابع للتحويل ده'; end if;

    v_mode := coalesce(nullif(e ->> 'mode', ''), 'BASE');
    v_qty := public.try_numeric(btrim(coalesce(e ->> 'qty', '')));
    if v_mode not in ('PIECE', 'BASE') or v_qty is null or v_qty < 0 then
      raise exception 'سطر %: كمية المرتجع لازم تكون رقم صفر أو أكبر', tl.line_no;
    end if;
    v_c := case when v_mode = 'PIECE' then round(v_qty * tl.uom_factor_snapshot, 4) else round(v_qty, 4) end;
    if v_c = 0 then continue; end if;
    v_pending := tl.sent_base - tl.received_base - tl.returned_base;
    if v_c > v_pending then
      raise exception 'سطر %: المرتجع (%) أكبر من المعلق (%)', tl.line_no, v_c, v_pending;
    end if;

    insert into public.stock_ledger (document_id, line_id, kitchen_id, location, product_id, movement_type, qty_base, unit_cost, posting_date)
    values (d.id, tl.line_id, d.kitchen_id, 'RETURN_PENDING', tl.product_id, 'RETURN_HOLD_OUT', -v_c, tl.unit_cost_snapshot, p_date),
           (d.id, tl.line_id, d.kitchen_id, 'WAREHOUSE', tl.product_id, 'TRANSFER_RETURN_IN', v_c, tl.unit_cost_snapshot, p_date);
    update public.transfer_lines set returned_base = returned_base + v_c where line_id = tl.line_id;
    v_total := v_total + v_c;
  end loop;

  if v_total = 0 then raise exception 'اكتب كمية مرتجع أكبر من صفر'; end if;
  if not exists (select 1 from public.transfer_lines
                  where document_id = d.id and returned_base < sent_base - coalesce(received_base, sent_base)) then
    update public.documents set status = 'CLOSED_PARTIAL' where id = d.id;
  end if;
end $$;

-- ---------- Reverse (بيشمل إلغاء تحويل لسه ما اتستلمش + الجرد) ----------
create or replace function public.reverse_document(p_doc uuid, p_reason text) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  d       public.documents%rowtype;
  v_new   uuid;
  v_ovr   text;
  r       record;
  v_avail numeric;
begin
  select * into d from public.documents where id = p_doc for update;
  if not found then raise exception 'المستند مش موجود'; end if;
  if not (public.my_role() in ('admin', 'manager') and public.has_kitchen(d.kitchen_id)
          and public.has_page(public.doc_type_page(d.doc_type))) then
    raise exception 'الـ Reverse للـ Admin أو الـ Manager على مطابخه';
  end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception 'سبب الـ Reverse مطلوب'; end if;
  if d.reverses_document_id is not null
     or not ((d.doc_type <> 'TRANSFER' and d.status = 'POSTED') or (d.doc_type = 'TRANSFER' and d.status = 'PENDING_RECEIPT')) then
    raise exception 'المستند % مش قابل للـ Reverse (التحويل بعد الاستلام بيتقفل بالمرتجع مش بالـ Reverse)', d.doc_no;
  end if;

  if public.is_period_closed(d.kitchen_id, d.doc_date) then
    if not public.is_admin() then
      raise exception 'الفترة مقفولة — الـ Reverse فيها للـ Admin بس';
    end if;
    v_ovr := p_reason;
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

-- ---------- Import: موديول Closing ----------
alter table public.import_batches drop constraint if exists import_batches_module_check;
alter table public.import_batches add constraint import_batches_module_check check (module in
  ('products', 'opening', 'purchases', 'wh_txn', 'waste', 'adjustments', 'closing'));

create or replace function public._module_page(p_module text) returns text
language sql immutable as $$
  select case p_module
    when 'products' then 'data_product' when 'opening' then 'opening_balance'
    when 'purchases' then 'purchases' when 'wh_txn' then 'warehouse_transactions'
    when 'waste' then 'waste' when 'adjustments' then 'stock_adjustments'
    when 'closing' then 'closing_stock_count' end
$$;

create or replace function public.import_start(
  p_module text, p_kitchen uuid, p_file text, p_total int,
  p_qty_mode text default 'BASE', p_mode text default 'upsert'
) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if p_module not in ('products', 'opening', 'purchases', 'wh_txn', 'waste', 'adjustments', 'closing') then
    raise exception 'موديول غير معروف: %', p_module;
  end if;
  if p_total is null or p_total < 1 then raise exception 'الملف فاضي'; end if;
  if p_total > 20000 then raise exception 'الحد الأقصى 20000 صف في الملف الواحد'; end if;
  if p_qty_mode not in ('PIECE', 'BASE') then raise exception 'qty_mode غلط'; end if;
  if p_mode not in ('upsert', 'insert', 'update') then raise exception 'mode غلط'; end if;
  perform public._assert_import_access(p_module, p_kitchen);
  insert into public.import_batches (module, kitchen_id, file_name, qty_mode, mode, total_rows)
  values (p_module, p_kitchen, p_file, p_qty_mode, p_mode, p_total)
  returning id into v_id;
  return v_id;
end $$;


-- ---------- Import: الفحص والحفظ (نفس 005 + Closing + سبب Waste إجباري) ----------
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
  v_cnt int; v_txt text; v_first_date date;
begin
  select * into b from public.import_batches where id = p_batch for update;
  delete from public.import_errors where batch_id = p_batch;
  update public.import_rows set is_valid = false, product_id = null, doc_date = null, qty_input = null,
         input_mode = null, qty_pieces = null, qty_base = null, reason = null, reason_id = null,
         note = null, parsed = null
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
        elsif b.module not in ('adjustments', 'closing') and v_num <= 0 then
          perform public._imp_err(p_batch, r.row_no, 'Qty', 'الكمية لازم تكون أكبر من صفر'); v_ok := false;
        elsif b.module = 'adjustments' and v_num = 0 then
          perform public._imp_err(p_batch, r.row_no, 'Qty', 'كمية التسوية لا يمكن أن تكون صفر'); v_ok := false;
        end if;
      end if;

      if v_ok then
        if v_mode = 'PIECE' then
          v_pieces := v_num; v_base := round(v_num * pr.uom_factor, 4);
        else
          v_base := v_num; v_pieces := round(v_num / pr.uom_factor, 4);
        end if;
        if v_base = 0 and b.module <> 'closing' then
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

      if v_ok then
        update public.import_rows set is_valid = true, product_id = pr.id, doc_date = v_date,
               qty_input = v_num, input_mode = v_mode, qty_pieces = v_pieces, qty_base = v_base,
               reason = v_reason, reason_id = v_reason_id, note = t_note
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
        perform public._imp_err(p_batch, r.row_no, 'Date', format('الفترة اللي فيها %s مقفولة — الإدخال بتاريخ رجعي للـ Admin بس', r.doc_date));
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
               case when b.module in ('waste', 'wh_txn') then -qty_base else qty_base end as eff
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

create or replace function public.import_commit(p_batch uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  b       public.import_batches%rowtype;
  v_errs  int;
  v_doc   uuid;
  v_type  text;
  d       record;
  v_ins   int := 0; v_upd int := 0; v_docs int := 0; v_lines int := 0; v_n int;
  v_result jsonb;
begin
  select * into b from public.import_batches where id = p_batch for update;
  if not found or b.created_by <> auth.uid() then raise exception 'الـ Batch مش موجود'; end if;
  if b.status = 'committed' then raise exception 'الـ Batch ده اتحفظ قبل كده'; end if;
  if b.status <> 'validated' then raise exception 'الملف لازم يعدّي الفحص الأول (Validate)'; end if;
  perform public._assert_import_access(b.module, b.kitchen_id);

  v_errs := public._import_validate(p_batch, b.override_reason);
  if v_errs > 0 then
    return jsonb_build_object('ok', false, 'errors', v_errs);
  end if;

  if b.module = 'products' then
    drop table if exists _fin;
    create temp table _fin on commit drop as
    with src as (
      select x.parsed, p.id as pid, p.cost as ex_cost, p.cost_per_uom as ex_cpu,
             coalesce((x.parsed ->> 'factor')::numeric, p.uom_factor, 1) as factor,
             (x.parsed ->> 'cost')::numeric as cost, (x.parsed ->> 'cost_per_uom')::numeric as cpu
        from public.import_rows x
        left join public.products p on p.syt_code = x.parsed ->> 'syt_code'
       where x.batch_id = p_batch and x.is_valid)
    select s.*,
      case when s.cost is not null then s.cost
           when s.cpu is not null then round(s.cpu * s.factor, 4)
           else coalesce(s.ex_cost, 0) end as f_cost,
      case when s.cpu is not null then s.cpu
           when s.cost is not null then round(s.cost / s.factor, 4)
           else coalesce(s.ex_cpu, 0) end as f_cpu
      from src s;

    update public.products p set
        name = coalesce(f.parsed ->> 'name', p.name),
        generic_code = coalesce(f.parsed ->> 'generic_code', p.generic_code),
        uom_name = coalesce(f.parsed ->> 'uom_name', p.uom_name),
        category = coalesce(f.parsed ->> 'category', p.category),
        uom_factor = f.factor, cost = f.f_cost, cost_per_uom = f.f_cpu
      from _fin f where f.pid = p.id;
    get diagnostics v_upd = row_count;

    insert into public.products (syt_code, generic_code, name, uom_name, category, uom_factor, cost, cost_per_uom)
    select f.parsed ->> 'syt_code', f.parsed ->> 'generic_code', f.parsed ->> 'name', f.parsed ->> 'uom_name',
           f.parsed ->> 'category', f.factor, f.f_cost, f.f_cpu
      from _fin f where f.pid is null;
    get diagnostics v_ins = row_count;
    v_result := jsonb_build_object('inserted', v_ins, 'updated', v_upd, 'mode', b.mode);
  else
    v_type := case b.module when 'opening' then 'OPENING' when 'purchases' then 'PURCHASE'
                when 'wh_txn' then 'WH_TXN' when 'waste' then 'WASTE' when 'adjustments' then 'ADJUSTMENT'
                when 'closing' then 'CLOSING' end;
    for d in select distinct doc_date from public.import_rows where batch_id = p_batch and is_valid order by doc_date loop
      insert into public.documents (doc_no, doc_type, kitchen_id, doc_date, status, import_batch_id, note)
      values (public._new_doc_no(v_type), v_type, b.kitchen_id, d.doc_date, 'DRAFT', p_batch,
              'Import: ' || coalesce(b.file_name, ''))
      returning id into v_doc;

      insert into public.document_lines (document_id, line_no, product_id, qty_input, input_mode, qty_pieces,
                                         qty_base, uom_factor_snapshot, reason, reason_id, note)
      select v_doc, row_number() over (order by x.row_no), x.product_id, x.qty_input, x.input_mode, x.qty_pieces,
             x.qty_base, p.uom_factor, x.reason, x.reason_id, x.note
        from public.import_rows x join public.products p on p.id = x.product_id
       where x.batch_id = p_batch and x.is_valid and x.doc_date = d.doc_date;
      get diagnostics v_n = row_count;

      if v_type = 'CLOSING' then
        perform public._post_closing(v_doc, b.override_reason);
      else
        perform public._post_document(v_doc, b.override_reason);
      end if;
      v_docs := v_docs + 1; v_lines := v_lines + v_n;
    end loop;
    v_result := jsonb_build_object('documents', v_docs, 'lines', v_lines);
  end if;

  update public.import_batches set status = 'committed', committed_at = now(), result = v_result where id = p_batch;
  return jsonb_build_object('ok', true) || v_result;
end $$;

-- ---------- التقارير (الـ Ledger مصدر الحقيقة؛ المعادلات مكتوبة هنا مرة واحدة) ----------
-- Opening للفترة = كل حركات WAREHOUSE قبل From + أي حركة OPENING داخل الفترة (الرصيد الافتتاحي المرفوع).
-- Transfer Out = TRANSFER_OUT ناقص أي مرتجع اتأكد (TRANSFER_RETURN_IN) — يعني المرتجع المعلق بيفضل Transfer Out.
-- Transfer In = المستلم فعليًا (Confirmed) بس.

-- Warehouse Stock = Opening + Purchases + Confirmed Transfer In − Transfer Out − Warehouse Transactions − Waste + Adjustments
create function public.report_warehouse_stock(p_kitchen uuid, p_from date, p_to date)
returns table (
  product_id uuid, syt_code text, generic_code text, product_name text, category text,
  uom_factor numeric, cost_per_uom numeric,
  opening numeric, purchases numeric, transfer_in numeric, transfer_out numeric,
  warehouse_txn numeric, waste numeric, adjustments numeric, closing_book numeric,
  in_transit numeric, return_pending numeric
)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  if not (public.has_kitchen(p_kitchen) and public.has_page('warehouse_stock')) then
    raise exception 'مش مسموحلك تشوف Warehouse Stock للمطبخ ده';
  end if;
  if p_from is null or p_to is null or p_from > p_to then raise exception 'الفترة غير صحيحة'; end if;

  return query
  with a as (
    select l.product_id,
      coalesce(sum(l.qty_base) filter (where l.location = 'WAREHOUSE' and (l.posting_date < p_from or l.movement_type = 'OPENING')), 0) as opening,
      coalesce(sum(l.qty_base) filter (where l.location = 'WAREHOUSE' and l.posting_date >= p_from and l.movement_type = 'PURCHASE'), 0) as purchases,
      coalesce(sum(l.qty_base) filter (where l.location = 'WAREHOUSE' and l.posting_date >= p_from and l.movement_type = 'TRANSFER_IN'), 0) as transfer_in,
      - coalesce(sum(l.qty_base) filter (where l.location = 'WAREHOUSE' and l.posting_date >= p_from and l.movement_type = 'TRANSFER_OUT'), 0)
      - coalesce(sum(l.qty_base) filter (where l.location = 'WAREHOUSE' and l.posting_date >= p_from and l.movement_type = 'TRANSFER_RETURN_IN'), 0) as transfer_out,
      - coalesce(sum(l.qty_base) filter (where l.location = 'WAREHOUSE' and l.posting_date >= p_from and l.movement_type = 'WH_TXN'), 0) as warehouse_txn,
      - coalesce(sum(l.qty_base) filter (where l.location = 'WAREHOUSE' and l.posting_date >= p_from and l.movement_type = 'WASTE'), 0) as waste,
      coalesce(sum(l.qty_base) filter (where l.location = 'WAREHOUSE' and l.posting_date >= p_from and l.movement_type in ('ADJ_PLUS', 'ADJ_MINUS')), 0) as adjustments,
      coalesce(sum(l.qty_base) filter (where l.location = 'IN_TRANSIT'), 0) as in_transit,
      coalesce(sum(l.qty_base) filter (where l.location = 'RETURN_PENDING'), 0) as return_pending
    from public.stock_ledger l
    where l.kitchen_id = p_kitchen and l.posting_date <= p_to
    group by l.product_id)
  select p.id, p.syt_code, p.generic_code, p.name, p.category, p.uom_factor, p.cost_per_uom,
         a.opening, a.purchases, a.transfer_in, a.transfer_out, a.warehouse_txn, a.waste, a.adjustments,
         a.opening + a.purchases + a.transfer_in - a.transfer_out - a.warehouse_txn - a.waste + a.adjustments,
         a.in_transit, a.return_pending
    from a join public.products p on p.id = a.product_id
   where a.opening <> 0 or a.purchases <> 0 or a.transfer_in <> 0 or a.transfer_out <> 0 or a.warehouse_txn <> 0
      or a.waste <> 0 or a.adjustments <> 0 or a.in_transit <> 0 or a.return_pending <> 0
   order by p.syt_code;
end $$;

-- Consumption = Opening + Purchases + Transfer In − Transfer Out − Closing − Waste
-- Closing = آخر جرد (Posted) تاريخه داخل الفترة، والحركات بتتحسب لحد تاريخ الجرد. منتج مش في الجرد = 0. مفيش جرد = كله 0.
create function public.report_consumption(p_kitchen uuid, p_from date, p_to date)
returns table (
  product_id uuid, syt_code text, generic_code text, product_name text, category text,
  uom_factor numeric, cost_per_uom numeric,
  opening numeric, purchases numeric, transfer_in numeric, transfer_out numeric, waste numeric,
  closing numeric, consumption numeric, has_closing boolean, closing_date date
)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
declare v_cdoc uuid; v_cdate date; v_end date;
begin
  if not (public.has_kitchen(p_kitchen) and public.has_page('consumption')) then
    raise exception 'مش مسموحلك تشوف Consumption للمطبخ ده';
  end if;
  if p_from is null or p_to is null or p_from > p_to then raise exception 'الفترة غير صحيحة'; end if;

  select d.id, d.doc_date into v_cdoc, v_cdate
    from public.documents d
   where d.kitchen_id = p_kitchen and d.doc_type = 'CLOSING' and d.status = 'POSTED' and d.reverses_document_id is null
     and d.doc_date between p_from and p_to
   order by d.doc_date desc limit 1;
  v_end := coalesce(v_cdate, p_to);

  return query
  with a as (
    select l.product_id,
      coalesce(sum(l.qty_base) filter (where l.location = 'WAREHOUSE' and (l.posting_date < p_from or l.movement_type = 'OPENING')), 0) as opening,
      coalesce(sum(l.qty_base) filter (where l.location = 'WAREHOUSE' and l.posting_date >= p_from and l.movement_type = 'PURCHASE'), 0) as purchases,
      coalesce(sum(l.qty_base) filter (where l.location = 'WAREHOUSE' and l.posting_date >= p_from and l.movement_type = 'TRANSFER_IN'), 0) as transfer_in,
      - coalesce(sum(l.qty_base) filter (where l.location = 'WAREHOUSE' and l.posting_date >= p_from and l.movement_type = 'TRANSFER_OUT'), 0)
      - coalesce(sum(l.qty_base) filter (where l.location = 'WAREHOUSE' and l.posting_date >= p_from and l.movement_type = 'TRANSFER_RETURN_IN'), 0) as transfer_out,
      - coalesce(sum(l.qty_base) filter (where l.location = 'WAREHOUSE' and l.posting_date >= p_from and l.movement_type = 'WASTE'), 0) as waste
    from public.stock_ledger l
    where l.kitchen_id = p_kitchen and l.posting_date <= v_end
    group by l.product_id),
  c as (
    select dl.product_id, sum(dl.qty_base) as qty
      from public.document_lines dl where dl.document_id = v_cdoc group by dl.product_id),
  j as (
    select coalesce(a.product_id, c.product_id) as pid,
           coalesce(a.opening, 0) as opening, coalesce(a.purchases, 0) as purchases,
           coalesce(a.transfer_in, 0) as transfer_in, coalesce(a.transfer_out, 0) as transfer_out,
           coalesce(a.waste, 0) as waste, coalesce(c.qty, 0) as closing, (c.product_id is not null) as in_closing
      from a full join c on c.product_id = a.product_id)
  select p.id, p.syt_code, p.generic_code, p.name, p.category, p.uom_factor, p.cost_per_uom,
         j.opening, j.purchases, j.transfer_in, j.transfer_out, j.waste, j.closing,
         j.opening + j.purchases + j.transfer_in - j.transfer_out - j.closing - j.waste,
         v_cdoc is not null, v_cdate
    from j join public.products p on p.id = j.pid
   where j.in_closing or j.opening <> 0 or j.purchases <> 0 or j.transfer_in <> 0 or j.transfer_out <> 0 or j.waste <> 0
   order by p.syt_code;
end $$;

-- ---------- Grants ----------
revoke all on public.transfer_lines from anon, authenticated;
grant select on public.transfer_lines to authenticated;

revoke execute on all functions in schema public from public, anon;
grant  execute on all functions in schema public to authenticated;
revoke execute on function
  public._post_document(uuid, text),
  public._post_closing(uuid, text),
  public._send_transfer(uuid, text),
  public._period_gate(uuid, date, text),
  public._import_validate(uuid, text),
  public._imp_err(uuid, int, text, text),
  public._assert_import_access(text, uuid),
  public._assert_product_manage(),
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

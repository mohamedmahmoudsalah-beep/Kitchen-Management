-- =====================================================================
-- KMS batch 3 / 007
--  1) الجرد (Closing) بيبقى Opening الفترة اللي بعدها: عند الـ Post بتتسجل تسوية Count Correction
--     بفرق (الجرد − رصيد الدفتر وقت تاريخ الجرد) للمنتجات المجرودة، فرصيد المخزن = الجرد،
--     وكل فترة بتبدأ من آخر جرد. (Reverse للجرد بيعكس التسوية معاه.)
--  2) مرتجع التحويل اللي مرجعش فعلًا: بيرجّعه استوك وبينزّله Missing (Adjustment) في خطوة واحدة.
--  3) Import للتحويلات (المطبخ المرسل = المختار، والمستلم عمود To) — بيتبعت In Transit والمستلم يأكد.
--  4) ملخص الـ Dashboard.
-- =====================================================================

alter table public.documents add column source_document_id uuid references public.documents (id);
create index documents_source_idx on public.documents (source_document_id) where source_document_id is not null;

-- ---------- فروق الجرد (مجرود − دفتر لحد تاريخ الجرد) ----------
create function public._closing_variances(p_doc uuid)
returns table (product_id uuid, factor numeric, variance numeric)
language sql stable security definer set search_path = public as $$
  select l.product_id, l.uom_factor_snapshot,
         round(l.qty_base - coalesce((
           select sum(sl.qty_base) from public.stock_ledger sl
            where sl.kitchen_id = d.kitchen_id and sl.location = 'WAREHOUSE'
              and sl.product_id = l.product_id and sl.posting_date <= d.doc_date), 0), 4)
    from public.document_lines l join public.documents d on d.id = l.document_id
   where l.document_id = p_doc
$$;

-- ---------- Closing: Post (+ تسوية فروق الجرد) ----------
drop function public._post_closing(uuid, text);
create function public._post_closing(p_doc uuid, p_override text default null, p_apply boolean default true) returns void
language plpgsql security definer set search_path = public as $$
declare
  d public.documents%rowtype; v_ovr text; v_adj uuid; v_n int; v_reason public.reasons%rowtype;
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

  if p_apply then
    select count(*) into v_n from public._closing_variances(d.id) where variance <> 0;
    if v_n > 0 then
      select * into v_reason from public.reasons where lower(btrim(name)) = 'count correction' limit 1;
      if not found then raise exception 'سبب Count Correction مش موجود في قايمة الأسباب'; end if;
      insert into public.documents (doc_no, doc_type, kitchen_id, doc_date, status, note, source_document_id)
      values (public._new_doc_no('ADJUSTMENT'), 'ADJUSTMENT', d.kitchen_id, d.doc_date, 'DRAFT',
              'Count variance of ' || d.doc_no, d.id)
      returning id into v_adj;
      insert into public.document_lines (document_id, line_no, product_id, qty_input, input_mode, qty_pieces, qty_base,
                                         uom_factor_snapshot, reason, reason_id)
      select v_adj, row_number() over (order by p.syt_code), v.product_id, abs(v.variance), 'BASE',
             round(v.variance / v.factor, 4), v.variance, v.factor, v_reason.name, v_reason.id
        from public._closing_variances(d.id) v join public.products p on p.id = v.product_id
       where v.variance <> 0;
      perform public._post_document(v_adj, v_ovr);
    end if;
  end if;
end $$;

-- Post موحّد
drop function public.post_document(uuid, text);
create function public.post_document(p_doc uuid, p_override_reason text default null, p_apply_count boolean default true) returns void
language plpgsql security definer set search_path = public as $$
declare d public.documents%rowtype;
begin
  select * into d from public.documents where id = p_doc;
  if not found then raise exception 'المستند مش موجود'; end if;
  if not (public.can_write_kitchen(d.kitchen_id) and public.has_page(public.doc_type_page(d.doc_type))) then
    raise exception 'مش مسموحلك تعمل Post للمستند ده';
  end if;
  if d.doc_type = 'CLOSING' then perform public._post_closing(p_doc, p_override_reason, p_apply_count);
  elsif d.doc_type = 'TRANSFER' then perform public._send_transfer(p_doc, p_override_reason);
  else perform public._post_document(p_doc, p_override_reason);
  end if;
end $$;

-- ---------- Reverse: core + wrapper (عكس الجرد بيعكس تسوية الفروق معاه) ----------
create function public._reverse_core(p_doc uuid, p_reason text) returns uuid
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
      raise exception 'الفترة مقفولة — الـ Reverse فيها للـ Admin بس';
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

create or replace function public.reverse_document(p_doc uuid, p_reason text) returns uuid
language plpgsql security definer set search_path = public as $$
declare d public.documents%rowtype;
begin
  select * into d from public.documents where id = p_doc;
  if not found then raise exception 'المستند مش موجود'; end if;
  if not (public.my_role() in ('admin', 'manager') and public.has_kitchen(d.kitchen_id)
          and public.has_page(public.doc_type_page(d.doc_type))) then
    raise exception 'الـ Reverse للـ Admin أو الـ Manager على مطابخه';
  end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception 'سبب الـ Reverse مطلوب'; end if;
  return public._reverse_core(p_doc, p_reason);
end $$;

-- ---------- مرتجع ما رجعش فعلًا: رجّعه استوك وبعدين نزّله Missing ----------
create function public.write_off_return(p_doc uuid, p_date date default current_date, p_override text default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  d public.documents%rowtype; v_lines jsonb; v_adj uuid; v_reason public.reasons%rowtype; v_ovr text;
begin
  select * into d from public.documents where id = p_doc for update;
  if not found or d.doc_type <> 'TRANSFER' then raise exception 'التحويل مش موجود'; end if;
  if d.status <> 'RETURN_PENDING' then raise exception 'التحويل % مفيهوش مرتجع معلق', d.doc_no; end if;
  if not (public.can_write_kitchen(d.kitchen_id) and public.has_page('kitchens_transfer') and public.has_page('stock_adjustments')) then
    raise exception 'ده للمطبخ المرسل وبيحتاج صلاحية Kitchens Transfer و Stock Adjustments';
  end if;
  select * into v_reason from public.reasons where lower(btrim(name)) = 'missing' limit 1;
  if not found then raise exception 'سبب Missing مش موجود في قايمة الأسباب'; end if;

  select jsonb_agg(jsonb_build_object('line_id', t.line_id, 'qty', (t.sent_base - t.received_base - t.returned_base)::text, 'mode', 'BASE'))
    into v_lines
    from public.transfer_lines t where t.document_id = d.id and t.sent_base - t.received_base - t.returned_base > 0;
  if v_lines is null then raise exception 'مفيش كميات معلقة'; end if;

  -- 1) رجّعها استوك (RETURN_PENDING -> WAREHOUSE) وقفل التحويل
  perform public.confirm_return(p_doc, v_lines, p_date, p_override);

  -- 2) نزّلها Missing
  v_ovr := public._period_gate(d.kitchen_id, p_date, p_override);
  insert into public.documents (doc_no, doc_type, kitchen_id, doc_date, status, note, source_document_id, override_reason)
  values (public._new_doc_no('ADJUSTMENT'), 'ADJUSTMENT', d.kitchen_id, p_date, 'DRAFT',
          'Missing from transfer ' || d.doc_no || ' (return not received)', d.id, v_ovr)
  returning id into v_adj;
  insert into public.document_lines (document_id, line_no, product_id, qty_input, input_mode, qty_pieces, qty_base,
                                     uom_factor_snapshot, reason, reason_id)
  select v_adj, row_number() over (order by l.line_no), l.product_id,
         (e ->> 'qty')::numeric, 'BASE', -round((e ->> 'qty')::numeric / l.uom_factor_snapshot, 4), -(e ->> 'qty')::numeric,
         l.uom_factor_snapshot, v_reason.name, v_reason.id
    from jsonb_array_elements(v_lines) e join public.document_lines l on l.id = (e ->> 'line_id')::uuid;
  perform public._post_document(v_adj, p_override);
  return v_adj;
end $$;

-- ---------- Dashboard ----------
create function public.dashboard_summary(p_kitchen uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_res jsonb;
begin
  if not (public.has_kitchen(p_kitchen) and public.has_page('dashboard')) then
    raise exception 'مش مسموحلك تشوف Dashboard للمطبخ ده';
  end if;
  select jsonb_build_object(
    'stock_value', coalesce((select sum(b.qty_base * p.cost_per_uom) from public.stock_balances b join public.products p on p.id = b.product_id
                              where b.kitchen_id = p_kitchen and b.location = 'WAREHOUSE'), 0),
    'products_in_stock', (select count(*) from public.stock_balances where kitchen_id = p_kitchen and location = 'WAREHOUSE' and qty_base > 0),
    'in_transit_value', coalesce((select sum(b.qty_base * p.cost_per_uom) from public.stock_balances b join public.products p on p.id = b.product_id
                                   where b.kitchen_id = p_kitchen and b.location = 'IN_TRANSIT'), 0),
    'return_pending_value', coalesce((select sum(b.qty_base * p.cost_per_uom) from public.stock_balances b join public.products p on p.id = b.product_id
                                       where b.kitchen_id = p_kitchen and b.location = 'RETURN_PENDING'), 0),
    'incoming_to_confirm', (select count(*) from public.documents where doc_type = 'TRANSFER' and counterpart_kitchen_id = p_kitchen
                             and status = 'PENDING_RECEIPT' and reverses_document_id is null),
    'outgoing_pending', (select count(*) from public.documents where doc_type = 'TRANSFER' and kitchen_id = p_kitchen
                          and status = 'PENDING_RECEIPT' and reverses_document_id is null),
    'returns_to_confirm', (select count(*) from public.documents where doc_type = 'TRANSFER' and kitchen_id = p_kitchen
                            and status = 'RETURN_PENDING' and reverses_document_id is null),
    'drafts', (select count(*) from public.documents where kitchen_id = p_kitchen and status = 'DRAFT'),
    'last_closing', (select max(doc_date) from public.documents where kitchen_id = p_kitchen and doc_type = 'CLOSING'
                       and status = 'POSTED' and reverses_document_id is null),
    'locked_through', (select max(to_date) from public.periods where kitchen_id = p_kitchen and status = 'CLOSED'),
    'cost_warnings', (select count(*) from public.products where cost_mismatch and is_active),
    'pending_users', case when public.is_admin() then (select count(*) from public.profiles where not is_active) else null end,
    'top_products', coalesce((select jsonb_agg(t) from (
        select p.syt_code, p.name as product_name, b.qty_base as qty, p.uom_factor, round(b.qty_base * p.cost_per_uom, 2) as value
          from public.stock_balances b join public.products p on p.id = b.product_id
         where b.kitchen_id = p_kitchen and b.location = 'WAREHOUSE' and b.qty_base > 0
         order by b.qty_base * p.cost_per_uom desc limit 8) t), '[]'::jsonb)
  ) into v_res;
  return v_res;
end $$;

-- ---------- Import: Transfers ----------
alter table public.import_rows add column counterpart_id uuid;
alter table public.import_batches drop constraint if exists import_batches_module_check;
alter table public.import_batches add constraint import_batches_module_check check (module in
  ('products', 'opening', 'purchases', 'wh_txn', 'waste', 'adjustments', 'closing', 'transfers'));

create or replace function public._module_page(p_module text) returns text
language sql immutable as $$
  select case p_module
    when 'products' then 'data_product' when 'opening' then 'opening_balance'
    when 'purchases' then 'purchases' when 'wh_txn' then 'warehouse_transactions'
    when 'waste' then 'waste' when 'adjustments' then 'stock_adjustments'
    when 'closing' then 'closing_stock_count' when 'transfers' then 'kitchens_transfer' end
$$;

create or replace function public.import_start(
  p_module text, p_kitchen uuid, p_file text, p_total int,
  p_qty_mode text default 'BASE', p_mode text default 'upsert'
) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if p_module not in ('products', 'opening', 'purchases', 'wh_txn', 'waste', 'adjustments', 'closing', 'transfers') then
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

-- ---------- Import: الفحص والحفظ (نفس 006 + Transfers) ----------
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
                when 'closing' then 'CLOSING' when 'transfers' then 'TRANSFER' end;
    for d in select distinct doc_date, counterpart_id from public.import_rows where batch_id = p_batch and is_valid order by doc_date, counterpart_id loop
      insert into public.documents (doc_no, doc_type, kitchen_id, doc_date, status, import_batch_id, counterpart_kitchen_id, note)
      values (public._new_doc_no(v_type), v_type, b.kitchen_id, d.doc_date, 'DRAFT', p_batch, d.counterpart_id,
              'Import: ' || coalesce(b.file_name, ''))
      returning id into v_doc;

      insert into public.document_lines (document_id, line_no, product_id, qty_input, input_mode, qty_pieces,
                                         qty_base, uom_factor_snapshot, reason, reason_id, note)
      select v_doc, row_number() over (order by x.row_no), x.product_id, x.qty_input, x.input_mode, x.qty_pieces,
             x.qty_base, p.uom_factor, x.reason, x.reason_id, x.note
        from public.import_rows x join public.products p on p.id = x.product_id
       where x.batch_id = p_batch and x.is_valid and x.doc_date = d.doc_date and x.counterpart_id is not distinct from d.counterpart_id;
      get diagnostics v_n = row_count;

      if v_type = 'CLOSING' then
        perform public._post_closing(v_doc, b.override_reason);
      elsif v_type = 'TRANSFER' then
        perform public._send_transfer(v_doc, b.override_reason);
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

-- ---------- Grants ----------
revoke execute on all functions in schema public from public, anon;
grant  execute on all functions in schema public to authenticated;
revoke execute on function
  public._post_document(uuid, text),
  public._post_closing(uuid, text, boolean),
  public._send_transfer(uuid, text),
  public._reverse_core(uuid, text),
  public._closing_variances(uuid),
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

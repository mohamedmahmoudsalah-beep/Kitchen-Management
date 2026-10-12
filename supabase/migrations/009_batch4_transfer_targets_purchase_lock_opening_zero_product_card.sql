-- =====================================================================
-- KMS batch 4 / 009
--  1) transfer_kitchens(): كل المطابخ الفعّالة كوجهة للتحويل (المستخدم بيفضل يشوف مطابخه بس في الـ Branch)
--  2) Purchases: الـ Reverse (التعديل بعد الاستلام) للـ Admin بس
--  3) Opening Balance: الصفر مسموح في الـ Import (السطر بيتسجّل ومفيش حركة في الـ Ledger)
--  4) product_card(): كل حركة على منتج (زيادة/نقص) + الكمية + مين عملها — لصفحة Audit Log
-- =====================================================================

-- ---------- 1) مطابخ الوجهة للتحويل ----------
create or replace function public.transfer_kitchens() returns table (id uuid, code text, name text)
language sql stable security definer set search_path = public as $$
  select k.id, k.code, k.name from public.kitchens k
   where k.is_active and public.is_active_user() and public.has_page('kitchens_transfer')
   order by k.name
$$;

-- ---------- 2) Purchases: Reverse للـ Admin بس ----------
create or replace function public.reverse_document(p_doc uuid, p_reason text) returns uuid
language plpgsql security definer set search_path = public as $$
declare d public.documents%rowtype;
begin
  select * into d from public.documents where id = p_doc;
  if not found then raise exception 'المستند مش موجود'; end if;
  if d.doc_type = 'PURCHASE' and not public.is_admin() then
    raise exception 'المشتريات بعد الاستلام (Post) مينفعش تتعدل أو تتعكس غير بواسطة الـ Admin';
  end if;
  if not (public.my_role() in ('admin', 'manager') and public.has_kitchen(d.kitchen_id)
          and public.has_page(public.doc_type_page(d.doc_type))) then
    raise exception 'الـ Reverse للـ Admin أو الـ Manager على مطابخه';
  end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception 'سبب الـ Reverse مطلوب'; end if;
  return public._reverse_core(p_doc, p_reason);
end $$;

-- ---------- 3) Post: السطر الصفري (Opening بصفر) بيتسجل في المستند بس ومبيعملش حركة ----------
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
      raise exception 'الفترة اللي فيها تاريخ % مقفولة — الإدخال بتاريخ رجعي للـ Admin بس', d.doc_date;
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

-- ---------- 3) Import: الرصيد الافتتاحي بصفر مسموح ----------
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
        elsif b.module not in ('adjustments', 'closing', 'opening') and v_num <= 0 then
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
        if v_base = 0 and b.module not in ('closing', 'opening') then
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


-- ---------- 4) Product Card ----------
create index if not exists stock_ledger_product_idx on public.stock_ledger (product_id, id);

-- p_kitchen = null => كل المطابخ المسموحة. p_from/p_to = null => كل التواريخ.
-- نفس صلاحية قراءة الـ Audit: Admin، أو Manager بصفحة audit_log على مطابخه.
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
                then sum(l.qty_base) over (partition by l.kitchen_id, l.location order by l.id) end as bal
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
   order by u.pd desc, u.ts desc;
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
  public.protect_root_profile(),
  public.apply_ledger_to_balance(),
  public.block_ledger_changes(),
  public.block_posted_delete(),
  public.set_updated_at()
from authenticated;

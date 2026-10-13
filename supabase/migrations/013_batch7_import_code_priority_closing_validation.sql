-- =====================================================================
-- KMS batch 7 / 013
--  1) Import: الـ Syt Code المطابق تمامًا له أولوية على الـ Generic (عشان اختيار الحجم من القايمة ينفع حتى لو الـ Syt = الـ Generic لمنتج تاني)
--  2) Import الجرد (Closing): فحص النقص مقابل الرصيد الحالي وقت الـ Validate (برقم الصف) بدل ما يفشل وقت الحفظ
--  3) رسالة أوضح لما تسوية الجرد مينفعش تتسجل
-- =====================================================================

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
        select array_agg(id order by syt_code) into v_ids from public.products where syt_code = t_code;   -- Syt Code مطابق تمامًا = أولوية
        if v_ids is null then
          select array_agg(id order by syt_code) into v_ids from public.products where generic_code = t_code;
        end if;
        v_n := coalesce(cardinality(v_ids), 0);
        if v_n = 0 then
          perform public._imp_err(p_batch, r.row_no, 'Code', format('الكود %s مش موجود في Data Product', t_code)); v_ok := false;
        elsif v_n > 1 then
          select string_agg(syt_code, ', ') into v_txt
            from (select syt_code from public.products where id = any (v_ids) order by syt_code limit 5) s;
          perform public._imp_err(p_batch, r.row_no, 'Code',
            format('الكود %s (Generic) بيطابق %s أحجام (Syt: %s) — اختار الحجم من القايمة في شاشة الـ Import، أو اكتب الـ Syt Code', t_code, v_n, v_txt)); v_ok := false;
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
    if b.module = 'closing' then
      for r in
        select i.row_no, i.doc_date, p.syt_code, i.qty_base as counted,
               coalesce((select sum(sl.qty_base) from public.stock_ledger sl
                          where sl.kitchen_id = b.kitchen_id and sl.location = 'WAREHOUSE'
                            and sl.product_id = i.product_id and sl.posting_date <= i.doc_date), 0) as book,
               coalesce(sb.qty_base, 0) as cur
          from public.import_rows i
          join public.products p on p.id = i.product_id
          left join public.stock_balances sb on sb.kitchen_id = b.kitchen_id and sb.location = 'WAREHOUSE' and sb.product_id = i.product_id
         where i.batch_id = p_batch and i.is_valid
      loop
        if r.counted - r.book < 0 and r.cur + (r.counted - r.book) < 0 then
          perform public._imp_err(p_batch, r.row_no, 'Qty',
            format('الجرد للمنتج %s بتاريخ %s = %s، ودفتر المخزن لحد التاريخ ده = %s (نقص %s)، بس رصيد المخزن الحالي %s — خصم النقص هيخليه سالب. يعني فيه حركات بعد تاريخ الجرد خلّصت الكمية. راجع الحركات اللي بعد التاريخ، أو سجّل المشتريات/التحويلات الناقصة، أو اعمل الجرد بتاريخ أحدث.',
                   r.syt_code, r.doc_date, r.counted, r.book, r.book - r.counted, r.cur));
          update public.import_rows set is_valid = false where batch_id = p_batch and row_no = r.row_no;
        end if;
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
      if d.source_document_id is not null then
        raise exception 'الجرد % طلّع نقص % للمنتج % عن دفتر المخزن بتاريخ %، بس رصيد المخزن الحالي % — خصم النقص هيخليه سالب (فيه حركات بعد تاريخ الجرد خلّصت الكمية). راجع الحركات اللي بعد التاريخ أو اعمل الجرد بتاريخ أحدث.',
          (select doc_no from public.documents where id = d.source_document_id), -r.eff, r.syt_code, d.doc_date, coalesce(v_avail, 0);
      end if;
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

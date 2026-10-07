-- =====================================================================
-- KMS batch 1 / 003 — Import: كل الملف يتفحص في جداول مؤقتة (staging)،
-- ولو في غلطة واحدة ولا صف بيتحفظ. لو سليم بيتحفظ في Transaction واحدة.
-- كل رفع بيتم لمطبخ واحد (اللوكيشن)، والـ Data Product عام.
-- =====================================================================

create table public.import_batches (
  id              uuid primary key default gen_random_uuid(),
  module          text not null check (module in
                    ('products', 'opening', 'purchases', 'wh_txn', 'waste', 'adjustments')),
  kitchen_id      uuid references public.kitchens (id),
  file_name       text,
  qty_mode        text not null default 'PIECE' check (qty_mode in ('PIECE', 'BASE')),
  status          text not null default 'staging'
                    check (status in ('staging', 'validated', 'failed', 'committed')),
  total_rows      int not null,
  error_count     int not null default 0,
  override_reason text,
  result          jsonb,
  created_by      uuid not null default auth.uid(),
  created_at      timestamptz not null default now(),
  committed_at    timestamptz
);

create table public.import_rows (
  batch_id   uuid not null references public.import_batches (id) on delete cascade,
  row_no     int  not null,
  raw        jsonb not null,
  -- بيتملوا في الـ validate
  is_valid   boolean not null default false,
  product_id uuid,
  doc_date   date,
  qty_input  numeric(18, 4),
  input_mode text,
  qty_pieces numeric(18, 4),
  qty_base   numeric(18, 4),
  reason     text,
  note       text,
  parsed     jsonb,
  primary key (batch_id, row_no)
);

create table public.import_errors (
  id          bigserial primary key,
  batch_id    uuid not null references public.import_batches (id) on delete cascade,
  module      text not null,
  kitchen_id  uuid,
  row_no      int  not null,            -- 0 = خطأ على مستوى الملف
  column_name text,
  reason      text not null,
  raw         jsonb,
  created_by  uuid,
  created_at  timestamptz not null default now()
);
create index import_errors_batch_idx on public.import_errors (batch_id, row_no);
create index import_errors_created_idx on public.import_errors (created_at desc);

create function public._module_page(p_module text) returns text
language sql immutable as $$
  select case p_module
    when 'products' then 'data_product' when 'opening' then 'opening_balance'
    when 'purchases' then 'purchases' when 'wh_txn' then 'warehouse_transactions'
    when 'waste' then 'waste' when 'adjustments' then 'stock_adjustments' end
$$;

create function public._assert_import_access(p_module text, p_kitchen uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_module = 'products' then
    if not public.is_admin() then raise exception 'استيراد Data Product للـ Admin بس'; end if;
    if p_kitchen is not null then raise exception 'Data Product مش مرتبط بمطبخ'; end if;
  else
    if p_kitchen is null then raise exception 'اختار المطبخ'; end if;
    if not (public.can_write_kitchen(p_kitchen)
            and public.has_page('import_export')
            and public.has_page(public._module_page(p_module))) then
      raise exception 'مش مسموحلك تعمل Import للمطبخ/الصفحة دي';
    end if;
  end if;
end $$;

create function public._imp_err(p_batch uuid, p_row int, p_col text, p_reason text) returns void
language sql security definer set search_path = public as $$
  insert into public.import_errors (batch_id, module, kitchen_id, row_no, column_name, reason, raw, created_by)
  select b.id, b.module, b.kitchen_id, p_row, p_col, p_reason, r.raw, b.created_by
    from public.import_batches b
    left join public.import_rows r on r.batch_id = b.id and r.row_no = p_row
   where b.id = p_batch
$$;

-- ---------- بدء الـ Import ----------
create function public.import_start(
  p_module text, p_kitchen uuid, p_file text, p_total int, p_qty_mode text default 'PIECE'
) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if p_module not in ('products', 'opening', 'purchases', 'wh_txn', 'waste', 'adjustments') then
    raise exception 'موديول غير معروف: %', p_module;
  end if;
  if p_total is null or p_total < 1 then raise exception 'الملف فاضي'; end if;
  if p_total > 20000 then raise exception 'الحد الأقصى 20000 صف في الملف الواحد'; end if;
  if p_qty_mode not in ('PIECE', 'BASE') then raise exception 'qty_mode غلط'; end if;
  perform public._assert_import_access(p_module, p_kitchen);
  insert into public.import_batches (module, kitchen_id, file_name, qty_mode, total_rows)
  values (p_module, p_kitchen, p_file, p_qty_mode, p_total)
  returning id into v_id;
  return v_id;
end $$;

create function public.import_stage_rows(p_batch uuid, p_rows jsonb) returns int
language plpgsql security definer set search_path = public as $$
declare b public.import_batches%rowtype; v_n int;
begin
  select * into b from public.import_batches where id = p_batch;
  if not found or b.created_by <> auth.uid() then raise exception 'الـ Batch مش موجود'; end if;
  if b.status <> 'staging' then raise exception 'الـ Batch مش في مرحلة الرفع'; end if;
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) > 2000 then
    raise exception 'الدفعة لازم تكون Array وأقل من 2000 صف';
  end if;
  insert into public.import_rows (batch_id, row_no, raw)
  select p_batch, (e ->> 'row_no')::int, e -> 'data' from jsonb_array_elements(p_rows) e;
  get diagnostics v_n = row_count;
  return v_n;
end $$;

-- ---------- الفحص (بيكتب الأخطاء في import_errors) ----------
create function public._import_validate(p_batch uuid, p_override text) returns int
language plpgsql security definer set search_path = public as $$
declare
  b        public.import_batches%rowtype;
  r        record;
  v_staged int;
  v_errs   int;
  v_ok     boolean;
  t_code text; t_date text; t_qty text; t_qp text; t_qb text; t_reason text; t_note text;
  t_syt text; t_gen text; t_name text; t_cat text; t_unit text; t_cost text; t_uom text;
  v_ids uuid[]; v_n int; pr public.products%rowtype;
  v_date date; v_num numeric; v_mode text; v_pieces numeric; v_base numeric; v_reason text;
  v_cost numeric; v_uom numeric; v_cnt int; v_txt text; v_first_date date;
  v_reasons text[] := array['Missing', 'Overage', 'Damage', 'Expired', 'Count Correction'];
begin
  select * into b from public.import_batches where id = p_batch for update;
  delete from public.import_errors where batch_id = p_batch;
  update public.import_rows set is_valid = false, product_id = null, doc_date = null, qty_input = null,
         input_mode = null, qty_pieces = null, qty_base = null, reason = null, note = null, parsed = null
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
      t_unit := nullif(btrim(r.raw ->> 'unit'), ''); t_cost := nullif(btrim(r.raw ->> 'cost'), '');
      t_uom := nullif(btrim(r.raw ->> 'uom'), '');
      v_cost := null; v_uom := null;

      if t_syt is null then perform public._imp_err(p_batch, r.row_no, 'Syt Code', 'Syt Code مطلوب'); v_ok := false; end if;
      if t_name is null then perform public._imp_err(p_batch, r.row_no, 'Product Name', 'اسم المنتج مطلوب'); v_ok := false; end if;
      if t_cost is not null then
        v_cost := public.try_numeric(t_cost);
        if v_cost is null or v_cost < 0 then
          perform public._imp_err(p_batch, r.row_no, 'Cost', format('Cost لازم يكون رقم ≥ 0 (القيمة: %s)', t_cost)); v_ok := false;
        end if;
      end if;
      if t_uom is not null then
        v_uom := public.try_numeric(t_uom);
        if v_uom is null or v_uom <= 0 then
          perform public._imp_err(p_batch, r.row_no, 'UOM', format('UOM لازم يكون رقم > 0 (القيمة: %s)', t_uom)); v_ok := false;
        end if;
      end if;
      if v_ok then
        update public.import_rows set is_valid = true,
          parsed = jsonb_build_object('syt_code', t_syt, 'generic_code', t_gen, 'name', t_name,
                                      'category', t_cat, 'unit', t_unit, 'cost', v_cost, 'uom', v_uom)
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
      pr := null; v_date := null; v_num := null; v_reason := null;

      -- التاريخ
      if t_date is null then
        perform public._imp_err(p_batch, r.row_no, 'Date', 'التاريخ مطلوب'); v_ok := false;
      else
        v_date := public.try_date(t_date);
        if v_date is null then
          perform public._imp_err(p_batch, r.row_no, 'Date', format('تاريخ غير صالح (%s) — المتوقع yyyy-mm-dd', t_date)); v_ok := false;
        end if;
      end if;

      -- الكود (Generic أو Syt)
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

      -- الكمية: Qty (حسب اختيار الرفع) أو Qty Pieces أو Qty Base
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
        elsif b.module <> 'adjustments' and v_num <= 0 then
          perform public._imp_err(p_batch, r.row_no, 'Qty', 'الكمية لازم تكون أكبر من صفر'); v_ok := false;
        elsif b.module = 'adjustments' and v_num = 0 then
          perform public._imp_err(p_batch, r.row_no, 'Qty', 'كمية التسوية لا يمكن أن تكون صفر'); v_ok := false;
        end if;
      end if;

      -- التحويل بين القطعة والوحدة الأساسية
      if v_ok then
        if v_mode = 'PIECE' then
          v_pieces := v_num; v_base := round(v_num * pr.uom_factor, 4);
        else
          v_base := v_num; v_pieces := round(v_num / pr.uom_factor, 4);
        end if;
        if v_base = 0 then
          perform public._imp_err(p_batch, r.row_no, 'Qty', 'الكمية بالوحدة الأساسية بتساوي صفر بعد التحويل'); v_ok := false;
        end if;
      end if;

      -- سبب التسوية
      if b.module = 'adjustments' then
        if t_reason is null then
          perform public._imp_err(p_batch, r.row_no, 'Reason', 'Reason مطلوب (Missing / Overage / Damage / Expired / Count Correction)'); v_ok := false;
        else
          select x into v_reason from unnest(v_reasons) x where lower(x) = lower(t_reason);
          if v_reason is null then
            perform public._imp_err(p_batch, r.row_no, 'Reason', format('Reason غير معروف (%s)', t_reason)); v_ok := false;
          elsif v_num is not null and (
                (v_reason = 'Overage' and v_num < 0)
             or (v_reason in ('Missing', 'Damage', 'Expired') and v_num > 0)) then
            perform public._imp_err(p_batch, r.row_no, 'Qty',
              format('%s لازم يكون بإشارة %s', v_reason, case when v_reason = 'Overage' then 'موجبة (زيادة)' else 'سالبة (نقص)' end));
            v_ok := false;
          end if;
        end if;
      end if;

      if v_ok then
        update public.import_rows set is_valid = true, product_id = pr.id, doc_date = v_date,
               qty_input = v_num, input_mode = v_mode, qty_pieces = v_pieces, qty_base = v_base,
               reason = v_reason, note = t_note
         where batch_id = p_batch and row_no = r.row_no;
      end if;
    end loop;

    -- الرصيد الافتتاحي: تاريخ واحد، منتج مرة واحدة، ومفيش رصيد افتتاحي فعّال قبل كده
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

    -- قفل الفترات
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

    -- الرصيد السالب ممنوع (الصافي التراكمي لكل منتج حسب التاريخ)
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

  select count(*) into v_errs from public.import_errors where batch_id = p_batch;
  update public.import_batches
     set status = case when v_errs = 0 then 'validated' else 'failed' end,
         error_count = v_errs, override_reason = p_override
   where id = p_batch;
  return v_errs;
end $$;

create function public.import_validate(p_batch uuid, p_override_reason text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare b public.import_batches%rowtype; v_errs int;
begin
  select * into b from public.import_batches where id = p_batch;
  if not found or b.created_by <> auth.uid() then raise exception 'الـ Batch مش موجود'; end if;
  if b.status = 'committed' then raise exception 'الـ Batch ده اتحفظ قبل كده'; end if;
  perform public._assert_import_access(b.module, b.kitchen_id);
  v_errs := public._import_validate(p_batch, p_override_reason);
  return jsonb_build_object('ok', v_errs = 0, 'errors', v_errs, 'rows', b.total_rows);
end $$;

-- ---------- الحفظ (Transaction واحدة: الدالة كلها = Transaction) ----------
create function public.import_commit(p_batch uuid) returns jsonb
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

  -- فحص تاني جوه نفس الـ Transaction (لو الداتا اتغيرت بين الفحص والحفظ)
  v_errs := public._import_validate(p_batch, b.override_reason);
  if v_errs > 0 then
    return jsonb_build_object('ok', false, 'errors', v_errs);
  end if;

  if b.module = 'products' then
    -- تحديث الموجود: القيم الفاضية في الملف بتحافظ على القيمة الحالية
    update public.products p set
        name = x.parsed ->> 'name',
        generic_code = coalesce(x.parsed ->> 'generic_code', p.generic_code),
        category = coalesce(x.parsed ->> 'category', p.category),
        base_unit = coalesce(x.parsed ->> 'unit', p.base_unit),
        cost = coalesce((x.parsed ->> 'cost')::numeric, p.cost),
        uom_factor = coalesce((x.parsed ->> 'uom')::numeric, p.uom_factor)
      from public.import_rows x
     where x.batch_id = p_batch and x.is_valid and p.syt_code = x.parsed ->> 'syt_code';
    get diagnostics v_upd = row_count;

    insert into public.products (syt_code, generic_code, name, category, base_unit, cost, uom_factor)
    select x.parsed ->> 'syt_code', x.parsed ->> 'generic_code', x.parsed ->> 'name',
           x.parsed ->> 'category', x.parsed ->> 'unit',
           coalesce((x.parsed ->> 'cost')::numeric, 0), coalesce((x.parsed ->> 'uom')::numeric, 1)
      from public.import_rows x
     where x.batch_id = p_batch and x.is_valid
       and not exists (select 1 from public.products p where p.syt_code = x.parsed ->> 'syt_code');
    get diagnostics v_ins = row_count;
    v_result := jsonb_build_object('inserted', v_ins, 'updated', v_upd);
  else
    v_type := case b.module when 'opening' then 'OPENING' when 'purchases' then 'PURCHASE'
                when 'wh_txn' then 'WH_TXN' when 'waste' then 'WASTE' when 'adjustments' then 'ADJUSTMENT' end;
    for d in select distinct doc_date from public.import_rows where batch_id = p_batch and is_valid order by doc_date loop
      insert into public.documents (doc_no, doc_type, kitchen_id, doc_date, status, import_batch_id, note)
      values (public._new_doc_no(v_type), v_type, b.kitchen_id, d.doc_date, 'DRAFT', p_batch,
              'Import: ' || coalesce(b.file_name, ''))
      returning id into v_doc;

      insert into public.document_lines (document_id, line_no, product_id, qty_input, input_mode, qty_pieces,
                                         qty_base, uom_factor_snapshot, reason, note)
      select v_doc, row_number() over (order by x.row_no), x.product_id, x.qty_input, x.input_mode, x.qty_pieces,
             x.qty_base, p.uom_factor, x.reason, x.note
        from public.import_rows x join public.products p on p.id = x.product_id
       where x.batch_id = p_batch and x.is_valid and x.doc_date = d.doc_date;
      get diagnostics v_n = row_count;

      perform public._post_document(v_doc, b.override_reason);
      v_docs := v_docs + 1; v_lines := v_lines + v_n;
    end loop;
    v_result := jsonb_build_object('documents', v_docs, 'lines', v_lines);
  end if;

  update public.import_batches set status = 'committed', committed_at = now(), result = v_result where id = p_batch;
  return jsonb_build_object('ok', true) || v_result;
end $$;

-- ---------- RLS (قراءة) ----------
alter table public.import_batches enable row level security;
alter table public.import_rows    enable row level security;
alter table public.import_errors  enable row level security;

create policy batches_read on public.import_batches for select to authenticated
  using (created_by = auth.uid() or public.is_admin()
         or (public.my_role() = 'manager' and kitchen_id is not null and public.has_kitchen(kitchen_id)));
create policy rows_read on public.import_rows for select to authenticated
  using (exists (select 1 from public.import_batches b where b.id = batch_id));
create policy errors_read on public.import_errors for select to authenticated
  using (created_by = auth.uid() or public.is_admin()
         or (public.my_role() = 'manager' and kitchen_id is not null and public.has_kitchen(kitchen_id)));

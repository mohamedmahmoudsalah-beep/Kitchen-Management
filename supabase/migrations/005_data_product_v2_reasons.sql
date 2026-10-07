-- =====================================================================
-- KMS batch 1.1 / 005
--  1) Data Product v2: الأعمدة بتاعة ملف Odoo (UoM, Category, Cost, Cost Pr UOM)
--     + "Base Qty per Syt" (كود السيستم = كام وحدة أساسية) + إضافة/تعديل/تحديث من الموقع
--     + الإدارة للـ Admin والـ Manager (الحذف والتعطيل للـ Admin بس)
--  2) قايمة أسباب مشتركة للـ Waste والـ Stock Adjustments (أي مستخدم يضيف سبب)
--  3) الرفع بالوحدة الأساسية (كيلو) كافتراضي
-- المفتاح: id (uuid) هو الـ PK الداخلي لكل العلاقات، و syt_code مفتاح العمل الفريد (بيتغير بأمان لأن مفيش حاجة بتشاور عليه).
-- =====================================================================

-- ---------- 1) products ----------
alter table public.products rename column cost to cost_per_uom;      -- سعر الوحدة الأساسية (كيلو/قطعة الجنريك)
alter table public.products rename column base_unit to uom_name;     -- عمود UoM زي ما هو في ملف Odoo (وصف بس)
alter table public.products add column cost numeric(18, 4) not null default 0 check (cost >= 0);  -- تكلفة كود السيستم
update public.products set cost = round(cost_per_uom * uom_factor, 4);
-- تنبيه لو Cost مش متسق مع (Base Qty per Syt × Cost per UOM)
alter table public.products add column cost_mismatch boolean generated always as (
  cost > 0 and cost_per_uom > 0 and abs(cost - uom_factor * cost_per_uom) > greatest(0.01, 0.02 * cost)
) stored;
comment on column public.products.uom_factor is 'Base Qty per Syt: كود السيستم الواحد = كام وحدة أساسية (كيلو)';
comment on column public.products.cost is 'تكلفة كود السيستم (القطعة/العبوة)';
comment on column public.products.cost_per_uom is 'تكلفة الوحدة الأساسية — دي اللي بتتجمّد في الـ Ledger';

-- ---------- 2) reasons ----------
create table public.reasons (
  id         uuid primary key default gen_random_uuid(),
  name       text not null check (length(btrim(name)) between 2 and 60),
  direction  text not null check (direction in ('INCREASE', 'DECREASE', 'ANY')),
  is_active  boolean not null default true,
  is_system  boolean not null default false,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);
create unique index reasons_name_uq on public.reasons (lower(btrim(name)));
select public.attach_audit('public.reasons');
insert into public.reasons (name, direction, is_system) values
  ('Missing', 'DECREASE', true), ('Overage', 'INCREASE', true), ('Damage', 'DECREASE', true),
  ('Expired', 'DECREASE', true), ('Count Correction', 'ANY', true), ('Merge', 'ANY', true);

alter table public.document_lines drop constraint if exists document_lines_reason_check;
alter table public.document_lines add column reason_id uuid references public.reasons (id);
alter table public.import_rows add column reason_id uuid;

-- أي مستخدم (مش Viewer) عنده صفحة Waste أو Stock Adjustments يقدر يضيف سبب
create function public.add_reason(p_name text, p_direction text) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_name text := btrim(coalesce(p_name, ''));
begin
  if not (public.my_role() in ('admin', 'manager', 'kitchen_user')
          and (public.has_page('waste') or public.has_page('stock_adjustments'))) then
    raise exception 'مش مسموحلك تضيف سبب';
  end if;
  if length(v_name) < 2 or length(v_name) > 60 then raise exception 'اسم السبب من 2 لـ 60 حرف'; end if;
  if p_direction not in ('INCREASE', 'DECREASE', 'ANY') then raise exception 'اتجاه السبب غلط'; end if;
  if exists (select 1 from public.reasons where lower(btrim(name)) = lower(v_name)) then
    raise exception 'السبب "%" موجود بالفعل', v_name;
  end if;
  insert into public.reasons (name, direction) values (v_name, p_direction) returning id into v_id;
  return v_id;
end $$;

create function public.set_reason_active(p_id uuid, p_active boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'تعطيل الأسباب للـ Admin بس'; end if;
  update public.reasons set is_active = p_active where id = p_id;
  if not found then raise exception 'السبب مش موجود'; end if;
end $$;

alter table public.reasons enable row level security;
create policy reasons_read on public.reasons for select to authenticated using (public.is_active_user());

-- ---------- 3) Data Product من الموقع ----------
create function public._assert_product_manage() returns void
language plpgsql security definer set search_path = public as $$
begin
  if not (public.my_role() in ('admin', 'manager') and public.has_page('data_product')) then
    raise exception 'إدارة Data Product للـ Admin والـ Manager بس';
  end if;
end $$;

-- إضافة (p_id null) أو تعديل منتج واحد. الحقول النصية: لو المفتاح موجود وفاضي = تفريغ، ولو مش موجود = زي ما هو.
-- الأرقام: الفاضي = القيمة الحالية. لو اتبعت Cost بس يتحسب Cost per UOM والعكس.
create function public.save_product(p_id uuid, p_data jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  ex       public.products%rowtype;
  t_syt    text := nullif(btrim(p_data ->> 'syt_code'), '');
  t_name   text := nullif(btrim(p_data ->> 'name'), '');
  v_factor numeric; v_cost numeric; v_cpu numeric;
  v_gen text; v_uomn text; v_cat text;
  v_id uuid;
begin
  perform public._assert_product_manage();
  if p_id is not null then
    select * into ex from public.products where id = p_id for update;
    if not found then raise exception 'المنتج مش موجود'; end if;
  end if;

  if nullif(btrim(p_data ->> 'factor'), '') is not null then
    v_factor := public.try_numeric(btrim(p_data ->> 'factor'));
    if v_factor is null or v_factor <= 0 then raise exception 'Base Qty per Syt لازم يكون رقم أكبر من صفر'; end if;
  end if;
  if nullif(btrim(p_data ->> 'cost'), '') is not null then
    v_cost := public.try_numeric(btrim(p_data ->> 'cost'));
    if v_cost is null or v_cost < 0 then raise exception 'Cost لازم يكون رقم ≥ 0'; end if;
  end if;
  if nullif(btrim(p_data ->> 'cost_per_uom'), '') is not null then
    v_cpu := public.try_numeric(btrim(p_data ->> 'cost_per_uom'));
    if v_cpu is null or v_cpu < 0 then raise exception 'Cost per UOM لازم يكون رقم ≥ 0'; end if;
  end if;

  if p_id is null then
    if t_syt is null then raise exception 'Syt Code مطلوب'; end if;
    if t_name is null then raise exception 'اسم المنتج مطلوب'; end if;
  else
    t_syt := coalesce(t_syt, ex.syt_code);
    t_name := coalesce(t_name, ex.name);
  end if;
  if exists (select 1 from public.products where syt_code = t_syt and id is distinct from p_id) then
    raise exception 'Syt Code % موجود بالفعل', t_syt;
  end if;

  v_gen  := case when p_data ? 'generic_code' then nullif(btrim(p_data ->> 'generic_code'), '') else ex.generic_code end;
  v_uomn := case when p_data ? 'uom_name' then nullif(btrim(p_data ->> 'uom_name'), '') else ex.uom_name end;
  v_cat  := case when p_data ? 'category' then nullif(btrim(p_data ->> 'category'), '') else ex.category end;

  v_factor := coalesce(v_factor, ex.uom_factor, 1);
  if v_cost is not null and v_cpu is null then v_cpu := round(v_cost / v_factor, 4);
  elsif v_cpu is not null and v_cost is null then v_cost := round(v_cpu * v_factor, 4);
  elsif v_cost is null and v_cpu is null then v_cost := coalesce(ex.cost, 0); v_cpu := coalesce(ex.cost_per_uom, 0);
  end if;

  if p_id is null then
    insert into public.products (syt_code, generic_code, name, uom_name, category, uom_factor, cost, cost_per_uom)
    values (t_syt, v_gen, t_name, v_uomn, v_cat, v_factor, v_cost, v_cpu) returning id into v_id;
  else
    update public.products set syt_code = t_syt, generic_code = v_gen, name = t_name, uom_name = v_uomn,
           category = v_cat, uom_factor = v_factor, cost = v_cost, cost_per_uom = v_cpu
     where id = p_id;
    v_id := p_id;
  end if;
  return v_id;
end $$;

create function public.delete_product(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'حذف المنتجات للـ Admin بس'; end if;
  if exists (select 1 from public.document_lines where product_id = p_id)
     or exists (select 1 from public.stock_ledger where product_id = p_id)
     or exists (select 1 from public.stock_balances where product_id = p_id) then
    raise exception 'المنتج مستخدم في حركات — عطّله (Inactive) بدل الحذف';
  end if;
  delete from public.products where id = p_id;
  if not found then raise exception 'المنتج مش موجود'; end if;
end $$;

create function public.set_product_active(p_id uuid, p_active boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'تعطيل المنتجات للـ Admin بس'; end if;
  update public.products set is_active = p_active where id = p_id;
  if not found then raise exception 'المنتج مش موجود'; end if;
end $$;

-- ---------- 4) Import: modes + صلاحيات Data Product + الافتراضي بالوحدة الأساسية ----------
alter table public.import_batches add column mode text not null default 'upsert'
  check (mode in ('upsert', 'insert', 'update'));
alter table public.import_batches alter column qty_mode set default 'BASE';

create or replace function public._assert_import_access(p_module text, p_kitchen uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_module = 'products' then
    perform public._assert_product_manage();
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

drop function public.import_start(text, uuid, text, int, text);
create function public.import_start(
  p_module text, p_kitchen uuid, p_file text, p_total int,
  p_qty_mode text default 'BASE', p_mode text default 'upsert'
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
  if p_mode not in ('upsert', 'insert', 'update') then raise exception 'mode غلط'; end if;
  perform public._assert_import_access(p_module, p_kitchen);
  insert into public.import_batches (module, kitchen_id, file_name, qty_mode, mode, total_rows)
  values (p_module, p_kitchen, p_file, p_qty_mode, p_mode, p_total)
  returning id into v_id;
  return v_id;
end $$;

-- الفحص (نفس منطق 003 + أعمدة Data Product الجديدة + قايمة الأسباب)
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
        elsif b.module <> 'adjustments' and v_num <= 0 then
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
        if v_base = 0 then
          perform public._imp_err(p_batch, r.row_no, 'Qty', 'الكمية بالوحدة الأساسية بتساوي صفر بعد التحويل'); v_ok := false;
        end if;
      end if;

      -- السبب من القايمة المشتركة: إجباري في Adjustments، واختياري في Waste (لكن لو اتكتب لازم يكون صح)
      if b.module = 'adjustments' or (b.module = 'waste' and t_reason is not null) then
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
                when 'wh_txn' then 'WH_TXN' when 'waste' then 'WASTE' when 'adjustments' then 'ADJUSTMENT' end;
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

      perform public._post_document(v_doc, b.override_reason);
      v_docs := v_docs + 1; v_lines := v_lines + v_n;
    end loop;
    v_result := jsonb_build_object('documents', v_docs, 'lines', v_lines);
  end if;

  update public.import_batches set status = 'committed', committed_at = now(), result = v_result where id = p_batch;
  return jsonb_build_object('ok', true) || v_result;
end $$;

-- ---------- 5) Post: التكلفة المتجمّدة = Cost per UOM (سعر الوحدة الأساسية) ----------
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
   where l.document_id = d.id
   order by (case when d.doc_type in ('OPENING', 'PURCHASE', 'ADJUSTMENT') then l.qty_base else -l.qty_base end) < 0,
            l.line_no;

  update public.documents set status = 'POSTED', posted_by = auth.uid(), posted_at = now() where id = d.id;
end $$;

-- ---------- 6) Grants (نفس 004 + الجديد) ----------
revoke all on public.reasons from anon, authenticated;
grant select on public.reasons to authenticated;

revoke execute on all functions in schema public from public, anon;
grant  execute on all functions in schema public to authenticated;
revoke execute on function
  public._post_document(uuid, text),
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

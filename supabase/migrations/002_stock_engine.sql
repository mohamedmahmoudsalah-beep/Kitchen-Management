-- =====================================================================
-- KMS batch 1 / 002 — Stock engine: Documents, Stock Ledger (append-only),
-- balances (no negative), period lock, Post / Reverse
-- كل مطبخ ليه Location مخزون واحد (WAREHOUSE). IN_TRANSIT / RETURN_PENDING
-- محجوزين للتحويلات (الدفعة 2).
-- =====================================================================

create sequence public.doc_no_seq;

create function public.doc_type_page(t text) returns text
language sql immutable as $$
  select case t
    when 'OPENING' then 'opening_balance'
    when 'PURCHASE' then 'purchases'
    when 'TRANSFER' then 'kitchens_transfer'
    when 'WH_TXN' then 'warehouse_transactions'
    when 'WASTE' then 'waste'
    when 'ADJUSTMENT' then 'stock_adjustments'
    when 'CLOSING' then 'closing_stock_count'
  end
$$;

create function public._new_doc_no(p_type text) returns text
language sql as $$
  select (case p_type
            when 'OPENING' then 'OPN' when 'PURCHASE' then 'PUR' when 'TRANSFER' then 'TRF'
            when 'WH_TXN' then 'WHT' when 'WASTE' then 'WST' when 'ADJUSTMENT' then 'ADJ'
            when 'CLOSING' then 'CLS' when 'REVERSAL' then 'REV' else 'DOC' end)
         || '-' || lpad(nextval('public.doc_no_seq')::text, 6, '0')
$$;

-- ---------- Documents ----------
create table public.documents (
  id                    uuid primary key default gen_random_uuid(),
  doc_no                text not null unique,
  doc_type              text not null check (doc_type in
                          ('OPENING','PURCHASE','TRANSFER','WH_TXN','WASTE','ADJUSTMENT','CLOSING')),
  kitchen_id            uuid not null references public.kitchens (id),
  doc_date              date not null,
  status                text not null default 'DRAFT' check (status in
                          ('DRAFT','POSTED','REVERSED','PENDING_RECEIPT','COMPLETED','RETURN_PENDING','CLOSED_PARTIAL')),
  counterpart_kitchen_id uuid references public.kitchens (id),
  reverses_document_id  uuid references public.documents (id),
  import_batch_id       uuid,
  note                  text,
  override_reason       text,           -- لو اتسجل في فترة مقفولة (Admin بس)
  odoo_po_id            bigint,         -- V2
  odoo_ref              text,           -- V2
  created_by            uuid default auth.uid(),
  posted_by             uuid,
  created_at            timestamptz not null default now(),
  posted_at             timestamptz
);
create index documents_kitchen_date_idx on public.documents (kitchen_id, doc_date);
-- رصيد افتتاحي واحد فعّال لكل مطبخ (لو عايز تعيد الرفع: Reverse الأول)
create unique index documents_one_opening on public.documents (kitchen_id)
  where doc_type = 'OPENING' and status = 'POSTED' and reverses_document_id is null;
create unique index documents_one_reversal on public.documents (reverses_document_id)
  where reverses_document_id is not null;

create table public.document_lines (
  id                  uuid primary key default gen_random_uuid(),
  document_id         uuid not null references public.documents (id),
  line_no             int  not null,
  product_id          uuid not null references public.products (id),
  qty_input           numeric(18, 4) not null,
  input_mode          text not null check (input_mode in ('PIECE', 'BASE')),
  qty_pieces          numeric(18, 4) not null,
  qty_base            numeric(18, 4) not null,   -- موجب، إلا في ADJUSTMENT (موجب=زيادة، سالب=نقص)
  uom_factor_snapshot numeric(18, 6) not null,
  unit_cost_snapshot  numeric(18, 4),            -- بتتجمّد وقت Post
  reason              text check (reason in ('Missing','Overage','Damage','Expired','Count Correction')),
  note                text,
  odoo_po_line_id     bigint,                    -- V2
  qty_ordered_base    numeric(18, 4),            -- V2
  unique (document_id, line_no),
  check (qty_base <> 0)
);
create index document_lines_product_idx on public.document_lines (product_id);

-- ---------- Stock Ledger (append-only) ----------
create table public.stock_ledger (
  id            bigserial primary key,
  document_id   uuid not null references public.documents (id),
  line_id       uuid not null references public.document_lines (id),
  kitchen_id    uuid not null references public.kitchens (id),
  location      text not null default 'WAREHOUSE' check (location in ('WAREHOUSE','IN_TRANSIT','RETURN_PENDING')),
  product_id    uuid not null references public.products (id),
  movement_type text not null check (movement_type in
                  ('OPENING','PURCHASE','TRANSFER_OUT','TRANSFER_IN','TRANSFER_RETURN_IN',
                   'WH_TXN','WASTE','ADJ_PLUS','ADJ_MINUS')),
  qty_base      numeric(18, 4) not null check (qty_base <> 0),   -- تأثير على الرصيد (موجب/سالب)
  unit_cost     numeric(18, 4) not null,
  posting_date  date not null,
  is_reversal   boolean not null default false,
  created_by    uuid default auth.uid(),
  created_at    timestamptz not null default now()
);
create index stock_ledger_kpd_idx on public.stock_ledger (kitchen_id, posting_date, product_id);
create index stock_ledger_doc_idx on public.stock_ledger (document_id);

create function public.block_ledger_changes() returns trigger
language plpgsql as $$ begin raise exception 'Stock Ledger append-only — اعمل حركة عكسية بدل التعديل أو الحذف'; end $$;
create trigger ledger_immutable before update or delete on public.stock_ledger
  for each row execute function public.block_ledger_changes();
create trigger ledger_no_truncate before truncate on public.stock_ledger
  for each statement execute function public.block_ledger_changes();

-- مفيش حذف حقيقي للمستندات المرحّلة أو سطورها
create function public.block_posted_delete() returns trigger
language plpgsql as $$
declare v_status text;
begin
  if tg_table_name = 'documents' then v_status := old.status;
  else select status into v_status from public.documents where id = old.document_id;
  end if;
  if v_status is distinct from 'DRAFT' then
    raise exception 'مينفعش حذف مستند اتعمله Post — استخدم Reverse';
  end if;
  return old;
end $$;
create trigger documents_no_delete before delete on public.documents
  for each row execute function public.block_posted_delete();
create trigger lines_no_delete before delete on public.document_lines
  for each row execute function public.block_posted_delete();

-- ---------- الأرصدة (CHECK >= 0 = حماية الرصيد السالب على مستوى الـ DB) ----------
create table public.stock_balances (
  kitchen_id uuid not null references public.kitchens (id),
  location   text not null,
  product_id uuid not null references public.products (id),
  qty_base   numeric(18, 4) not null check (qty_base >= 0),
  primary key (kitchen_id, location, product_id)
);

create function public.apply_ledger_to_balance() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  -- UPDATE الأول: الـ INSERT ... ON CONFLICT بيفحص الـ CHECK على القيمة الجديدة قبل ما يكتشف التعارض
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
create trigger ledger_to_balance after insert on public.stock_ledger
  for each row execute function public.apply_ledger_to_balance();

-- ---------- قفل الفترات ----------
create table public.periods (
  id            uuid primary key default gen_random_uuid(),
  kitchen_id    uuid not null references public.kitchens (id),
  from_date     date not null,
  to_date       date not null,
  status        text not null default 'CLOSED' check (status in ('OPEN', 'CLOSED')),
  closed_by     uuid,
  closed_at     timestamptz,
  reopen_reason text,
  check (from_date <= to_date),
  exclude using gist (kitchen_id with =, daterange(from_date, to_date, '[]') with &&)
);
select public.attach_audit('public.periods');
select public.attach_audit('public.documents');

create function public.is_period_closed(p_kitchen uuid, p_date date) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.periods p
                  where p.kitchen_id = p_kitchen and p.status = 'CLOSED'
                    and p_date between p.from_date and p.to_date)
$$;

create function public.close_period(p_kitchen uuid, p_from date, p_to date) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if not (public.my_role() in ('admin', 'manager') and public.has_kitchen(p_kitchen)) then
    raise exception 'قفل الفترة للـ Admin أو الـ Manager على مطابخه';
  end if;
  insert into public.periods (kitchen_id, from_date, to_date, status, closed_by, closed_at)
  values (p_kitchen, p_from, p_to, 'CLOSED', auth.uid(), now())
  returning id into v_id;
  return v_id;
end $$;

create function public.reopen_period(p_period uuid, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'فتح الفترة للـ Admin بس'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception 'سبب إعادة الفتح مطلوب'; end if;
  update public.periods set status = 'OPEN', reopen_reason = p_reason where id = p_period;
  if not found then raise exception 'الفترة مش موجودة'; end if;
end $$;

-- ---------- Post (داخلي: من غير فحص صلاحيات، بيستدعيه Import / post_document) ----------
create function public._post_document(p_doc uuid, p_override_reason text default null) returns void
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

  -- تجميد التكلفة وقت الترحيل
  update public.document_lines l set unit_cost_snapshot = p.cost
    from public.products p where p.id = l.product_id and l.document_id = d.id;

  -- فحص الرصيد المتاح (الصافي لكل منتج)
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

  -- كتابة الـ Ledger (الزيادات الأول عشان الصافي داخل نفس المستند يتحسب صح)
  insert into public.stock_ledger
    (document_id, line_id, kitchen_id, location, product_id, movement_type, qty_base, unit_cost, posting_date)
  select d.id, l.id, d.kitchen_id, 'WAREHOUSE', l.product_id,
         case d.doc_type
           when 'OPENING' then 'OPENING' when 'PURCHASE' then 'PURCHASE'
           when 'WH_TXN' then 'WH_TXN' when 'WASTE' then 'WASTE'
           when 'ADJUSTMENT' then case when l.qty_base > 0 then 'ADJ_PLUS' else 'ADJ_MINUS' end
         end,
         case when d.doc_type in ('OPENING', 'PURCHASE', 'ADJUSTMENT') then l.qty_base else -l.qty_base end,
         p.cost, d.doc_date
    from public.document_lines l join public.products p on p.id = l.product_id
   where l.document_id = d.id
   order by (case when d.doc_type in ('OPENING', 'PURCHASE', 'ADJUSTMENT') then l.qty_base else -l.qty_base end) < 0,
            l.line_no;

  update public.documents set status = 'POSTED', posted_by = auth.uid(), posted_at = now() where id = d.id;
end $$;

create function public.post_document(p_doc uuid, p_override_reason text default null) returns void
language plpgsql security definer set search_path = public as $$
declare d public.documents%rowtype;
begin
  select * into d from public.documents where id = p_doc;
  if not found then raise exception 'المستند مش موجود'; end if;
  if not (public.can_write_kitchen(d.kitchen_id) and public.has_page(public.doc_type_page(d.doc_type))) then
    raise exception 'مش مسموحلك تعمل Post للمستند ده';
  end if;
  perform public._post_document(p_doc, p_override_reason);
end $$;

-- ---------- Reverse (حركة عكسية — مفيش حذف) ----------
create function public.reverse_document(p_doc uuid, p_reason text) returns uuid
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
  if d.status <> 'POSTED' or d.reverses_document_id is not null then
    raise exception 'المستند % مش قابل للـ Reverse', d.doc_no;
  end if;

  if public.is_period_closed(d.kitchen_id, d.doc_date) then
    if not public.is_admin() then
      raise exception 'الفترة مقفولة — الـ Reverse فيها للـ Admin بس';
    end if;
    v_ovr := p_reason;
  end if;

  for r in
    select l.location, l.product_id, pr.syt_code, -sum(l.qty_base) as eff
      from public.stock_ledger l join public.products pr on pr.id = l.product_id
     where l.document_id = d.id
     group by l.location, l.product_id, pr.syt_code
    having -sum(l.qty_base) < 0
  loop
    select coalesce(qty_base, 0) into v_avail from public.stock_balances
     where kitchen_id = d.kitchen_id and location = r.location and product_id = r.product_id;
    if coalesce(v_avail, 0) + r.eff < 0 then
      raise exception 'الرصيد الحالي للمنتج % (%) مش بيسمح بالـ Reverse — استخدم Stock Adjustment', r.syt_code, coalesce(v_avail, 0);
    end if;
  end loop;

  insert into public.documents (doc_no, doc_type, kitchen_id, doc_date, status, reverses_document_id,
                                note, override_reason, posted_by, posted_at)
  values (public._new_doc_no('REVERSAL'), d.doc_type, d.kitchen_id, d.doc_date, 'POSTED', d.id,
          'Reversal of ' || d.doc_no || ': ' || p_reason, v_ovr, auth.uid(), now())
  returning id into v_new;

  insert into public.document_lines (document_id, line_no, product_id, qty_input, input_mode, qty_pieces,
                                     qty_base, uom_factor_snapshot, unit_cost_snapshot, reason, note)
  select v_new, line_no, product_id, qty_input, input_mode, qty_pieces, qty_base,
         uom_factor_snapshot, unit_cost_snapshot, reason, note
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

-- ---------- RLS (قراءة) ----------
alter table public.documents      enable row level security;
alter table public.document_lines enable row level security;
alter table public.stock_ledger   enable row level security;
alter table public.stock_balances enable row level security;
alter table public.periods        enable row level security;

create policy documents_read on public.documents for select to authenticated
  using (public.has_kitchen(kitchen_id) and public.has_page(public.doc_type_page(doc_type)));
create policy lines_read on public.document_lines for select to authenticated
  using (exists (select 1 from public.documents d where d.id = document_id));
create policy ledger_read on public.stock_ledger for select to authenticated
  using (public.has_kitchen(kitchen_id));
create policy balances_read on public.stock_balances for select to authenticated
  using (public.has_kitchen(kitchen_id));
create policy periods_read on public.periods for select to authenticated
  using (public.has_kitchen(kitchen_id));

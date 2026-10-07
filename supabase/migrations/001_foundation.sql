-- =====================================================================
-- KMS batch 1 / 001 — Foundation: kitchens, pages, users & permissions,
-- audit log, Data Product (master data)
-- كل الكتابة بتتم من خلال RPCs (security definer)؛ الجداول للقراءة بس عبر RLS.
-- =====================================================================
create extension if not exists btree_gist;

-- ---------- helpers ----------
create function public.app_root_email() returns text
language sql immutable as $$ select 'mohamed.mahmoudsalah@breadfast.com'::text $$;

create function public.set_updated_at() returns trigger
language plpgsql as $$ begin new.updated_at := now(); return new; end $$;

create function public.try_date(t text) returns date
language plpgsql immutable as $$
begin
  if t is null or t !~ '^\d{4}-\d{2}-\d{2}$' then return null; end if;
  return t::date;
exception when others then return null;
end $$;

create function public.try_numeric(t text) returns numeric
language plpgsql immutable as $$
begin
  if t is null or t !~ '^[+-]?(\d+(\.\d*)?|\.\d+)$' then return null; end if;
  return t::numeric;
exception when others then return null;
end $$;

-- ---------- kitchens & pages ----------
create type public.app_role as enum ('admin', 'manager', 'kitchen_user', 'viewer');

create table public.kitchens (
  id        uuid primary key default gen_random_uuid(),
  code      text not null unique,
  name      text not null,
  is_active boolean not null default true
);
insert into public.kitchens (code, name) values
  ('PLUS_MALL', 'Plus Mall'), ('REHAB', 'Rehab'), ('MAADI', 'Maadi'), ('NC7', 'NC7');

create table public.pages (
  key   text primary key,
  title text not null,
  sort  int  not null
);
insert into public.pages (key, title, sort) values
  ('dashboard', 'Dashboard', 1),
  ('opening_balance', 'Opening Balance', 2),
  ('purchases', 'Purchases', 3),
  ('kitchens_transfer', 'Kitchens Transfer', 4),
  ('warehouse_transactions', 'Warehouse Transactions', 5),
  ('waste', 'Waste', 6),
  ('closing_stock_count', 'Closing / Stock Count', 7),
  ('consumption', 'Consumption', 8),
  ('warehouse_stock', 'Warehouse Stock', 9),
  ('stock_adjustments', 'Stock Adjustments', 10),
  ('data_product', 'Data Product', 11),
  ('import_export', 'Import / Export', 12),
  ('import_errors', 'Import Errors', 13),
  ('access_control', 'Access Control', 14),
  ('audit_log', 'Audit Log', 15);

-- ---------- users & permissions ----------
create table public.profiles (
  user_id    uuid primary key references auth.users (id) on delete cascade,
  email      text not null,
  full_name  text,
  role       public.app_role not null default 'viewer',
  is_active  boolean not null default false,
  is_root    boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index profiles_email_lower_uq on public.profiles (lower(email));
create trigger profiles_updated before update on public.profiles
  for each row execute function public.set_updated_at();

create table public.user_kitchens (
  user_id    uuid not null references public.profiles (user_id) on delete cascade,
  kitchen_id uuid not null references public.kitchens (id) on delete cascade,
  primary key (user_id, kitchen_id)
);

create table public.user_pages (
  user_id  uuid not null references public.profiles (user_id) on delete cascade,
  page_key text not null references public.pages (key) on delete cascade,
  primary key (user_id, page_key),
  check (page_key <> 'access_control')   -- Access Control للـ Admin بس
);

-- دعوة مسبقة: الـ Admin يكتب الإيميل وصلاحياته قبل أول دخول
create table public.access_invites (
  email       text primary key,
  role        public.app_role not null default 'viewer',
  is_active   boolean not null default true,
  kitchen_ids uuid[] not null default '{}',
  page_keys   text[] not null default '{}',
  created_by  uuid,
  created_at  timestamptz not null default now(),
  check (email = lower(email))
);

-- الـ Admin الأساسي: مينفعش يتعطل ولا يتحذف ولا يتغير دوره
create function public.protect_root_profile() returns trigger
language plpgsql as $$
begin
  if tg_op = 'DELETE' then
    if old.is_root then raise exception 'مينفعش حذف الـ Admin الأساسي'; end if;
    return old;
  elsif tg_op = 'INSERT' then
    if new.is_root and lower(new.email) <> public.app_root_email() then
      raise exception 'is_root مسموح للـ Admin الأساسي بس';
    end if;
    return new;
  else
    if old.is_root then
      if new.is_root is not true or new.role <> 'admin' or new.is_active is not true
         or lower(new.email) <> lower(old.email) then
        raise exception 'مينفعش تعديل أو تعطيل الـ Admin الأساسي';
      end if;
    elsif new.is_root then
      raise exception 'is_root مسموح للـ Admin الأساسي بس';
    end if;
    return new;
  end if;
end $$;
create trigger profiles_protect_root before insert or update or delete on public.profiles
  for each row execute function public.protect_root_profile();

-- الـ helpers اللي بتستخدمها الـ RLS
create function public.my_role() returns text
language sql stable security definer set search_path = public as $$
  select role::text from public.profiles where user_id = auth.uid() and is_active
$$;

create function public.is_active_user() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where user_id = auth.uid() and is_active)
$$;

create function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(public.my_role() = 'admin', false)
$$;

create function public.has_kitchen(kid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select public.is_admin() or (
    public.is_active_user() and exists (
      select 1 from public.user_kitchens uk where uk.user_id = auth.uid() and uk.kitchen_id = kid))
$$;

create function public.has_page(pkey text) returns boolean
language sql stable security definer set search_path = public as $$
  select public.is_admin() or (
    pkey <> 'access_control' and public.is_active_user() and exists (
      select 1 from public.user_pages up where up.user_id = auth.uid() and up.page_key = pkey))
$$;

create function public.can_write_kitchen(kid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(public.my_role() in ('admin', 'manager', 'kitchen_user'), false)
         and public.has_kitchen(kid)
$$;

-- تسجيل الدخول مقصور على دومين Breadfast (على مستوى الـ DB مش الواجهة بس)
create function public.enforce_email_domain() returns trigger
language plpgsql as $$
begin
  if lower(coalesce(new.email, '')) not like '%@breadfast.com' then
    raise exception 'Only @breadfast.com accounts are allowed';
  end if;
  return new;
end $$;

create trigger auth_users_email_domain before insert or update of email on auth.users
  for each row execute function public.enforce_email_domain();

-- أول دخول: Root = Admin فعّال | مدعو = حسب الدعوة | غير كده = Profile غير Active
create function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_inv  public.access_invites%rowtype;
  v_name text := coalesce(new.raw_user_meta_data ->> 'full_name', new.raw_user_meta_data ->> 'name');
begin
  if lower(new.email) = public.app_root_email() then
    insert into public.profiles (user_id, email, full_name, role, is_active, is_root)
    values (new.id, lower(new.email), v_name, 'admin', true, true);
    return new;
  end if;

  select * into v_inv from public.access_invites where email = lower(new.email);
  if found then
    insert into public.profiles (user_id, email, full_name, role, is_active)
    values (new.id, lower(new.email), v_name, v_inv.role, v_inv.is_active);
    insert into public.user_kitchens (user_id, kitchen_id)
      select new.id, k from unnest(v_inv.kitchen_ids) k
      where exists (select 1 from public.kitchens where id = k);
    insert into public.user_pages (user_id, page_key)
      select new.id, p from unnest(v_inv.page_keys) p
      where p <> 'access_control' and exists (select 1 from public.pages where key = p);
    delete from public.access_invites where email = v_inv.email;
  else
    insert into public.profiles (user_id, email, full_name, role, is_active)
    values (new.id, lower(new.email), v_name, 'viewer', false);
  end if;
  return new;
end $$;

create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------- Audit log (بيتكتب من الـ DB تلقائيًا) ----------
create table public.audit_log (
  id         bigserial primary key,
  at         timestamptz not null default now(),
  user_id    uuid,
  user_email text,
  table_name text not null,
  row_id     text,
  action     text not null,
  kitchen_id uuid,
  old_data   jsonb,
  new_data   jsonb
);
create index audit_log_at_idx on public.audit_log (at desc);
create index audit_log_kitchen_idx on public.audit_log (kitchen_id, at desc);

create function public.audit_row() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_old jsonb; v_new jsonb; v_row jsonb; v_email text;
begin
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

create function public.audit_block_changes() returns trigger
language plpgsql as $$ begin raise exception 'Audit log append-only'; end $$;
create trigger audit_log_immutable before update or delete on public.audit_log
  for each row execute function public.audit_block_changes();

create function public.attach_audit(p_table regclass) returns void
language plpgsql as $$
begin
  execute format('create trigger audit_ins after insert on %s for each row execute function public.audit_row()', p_table);
  execute format('create trigger audit_upd after update on %s for each row when (old.* is distinct from new.*) execute function public.audit_row()', p_table);
  execute format('create trigger audit_del after delete on %s for each row execute function public.audit_row()', p_table);
end $$;

select public.attach_audit('public.kitchens');
select public.attach_audit('public.profiles');
select public.attach_audit('public.user_kitchens');
select public.attach_audit('public.user_pages');
select public.attach_audit('public.access_invites');

-- ---------- Data Product (Master Data) ----------
create table public.products (
  id          uuid primary key default gen_random_uuid(),
  generic_code text,                               -- ممكن يتكرر على أكتر من منتج
  syt_code    text not null unique,                -- فريد
  name        text not null,
  category    text,
  base_unit   text,
  uom_factor  numeric(18, 6) not null default 1 check (uom_factor > 0),  -- UOM: القطعة = uom_factor وحدة أساسية
  cost        numeric(18, 4) not null default 0 check (cost >= 0),       -- تكلفة الوحدة الأساسية
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index products_generic_idx on public.products (generic_code);
create index products_name_idx on public.products (lower(name));
create trigger products_updated before update on public.products
  for each row execute function public.set_updated_at();
select public.attach_audit('public.products');

-- ---------- Access Control RPCs (Admin بس) ----------
create function public.set_user_access(
  p_user uuid, p_role text, p_active boolean, p_kitchens uuid[], p_pages text[]
) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'للـ Admin بس'; end if;
  update public.profiles set role = p_role::public.app_role, is_active = p_active
   where user_id = p_user;
  if not found then raise exception 'المستخدم مش موجود'; end if;

  delete from public.user_kitchens
   where user_id = p_user and not (kitchen_id = any (coalesce(p_kitchens, '{}')));
  insert into public.user_kitchens (user_id, kitchen_id)
    select p_user, k from unnest(coalesce(p_kitchens, '{}')) k
    where exists (select 1 from public.kitchens where id = k)
  on conflict do nothing;

  delete from public.user_pages
   where user_id = p_user and not (page_key = any (coalesce(p_pages, '{}')));
  insert into public.user_pages (user_id, page_key)
    select p_user, p from unnest(coalesce(p_pages, '{}')) p
    where p <> 'access_control' and exists (select 1 from public.pages where key = p)
  on conflict do nothing;
end $$;

create function public.invite_user(
  p_email text, p_role text, p_active boolean, p_kitchens uuid[], p_pages text[]
) returns void
language plpgsql security definer set search_path = public as $$
declare v_email text := lower(btrim(p_email));
begin
  if not public.is_admin() then raise exception 'للـ Admin بس'; end if;
  if v_email not like '%@breadfast.com' then raise exception 'الإيميل لازم يكون @breadfast.com'; end if;
  if exists (select 1 from public.profiles where lower(email) = v_email) then
    raise exception 'المستخدم ده موجود بالفعل — عدّل صلاحياته من الجدول';
  end if;
  insert into public.access_invites (email, role, is_active, kitchen_ids, page_keys, created_by)
  values (v_email, p_role::public.app_role, p_active, coalesce(p_kitchens, '{}'),
          array(select p from unnest(coalesce(p_pages, '{}')) p where p <> 'access_control'), auth.uid())
  on conflict (email) do update
    set role = excluded.role, is_active = excluded.is_active,
        kitchen_ids = excluded.kitchen_ids, page_keys = excluded.page_keys;
end $$;

create function public.delete_invite(p_email text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'للـ Admin بس'; end if;
  delete from public.access_invites where email = lower(btrim(p_email));
end $$;

-- ---------- RLS (قراءة بس) ----------
alter table public.kitchens       enable row level security;
alter table public.pages          enable row level security;
alter table public.profiles       enable row level security;
alter table public.user_kitchens  enable row level security;
alter table public.user_pages     enable row level security;
alter table public.access_invites enable row level security;
alter table public.audit_log      enable row level security;
alter table public.products       enable row level security;

create policy kitchens_read on public.kitchens for select to authenticated
  using (public.has_kitchen(id));
create policy pages_read on public.pages for select to authenticated
  using (public.is_active_user());
create policy profiles_read on public.profiles for select to authenticated
  using (user_id = auth.uid() or public.is_admin());
create policy user_kitchens_read on public.user_kitchens for select to authenticated
  using (user_id = auth.uid() or public.is_admin());
create policy user_pages_read on public.user_pages for select to authenticated
  using (user_id = auth.uid() or public.is_admin());
create policy invites_read on public.access_invites for select to authenticated
  using (public.is_admin());
create policy audit_read on public.audit_log for select to authenticated
  using (public.is_admin() or (
    public.my_role() = 'manager' and public.has_page('audit_log')
    and kitchen_id is not null and public.has_kitchen(kitchen_id)));
create policy products_read on public.products for select to authenticated
  using (public.is_active_user());

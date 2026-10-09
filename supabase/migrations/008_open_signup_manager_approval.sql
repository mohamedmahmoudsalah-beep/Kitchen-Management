-- =====================================================================
-- KMS batch 3.1 / 008 — تسجيل الدخول لأي حساب جوجل، والدخول بموافقة Admin أو Manager
--  * مفيش تقييد على دومين الإيميل (اتشال الـ Trigger على auth.users).
--  * أي حد يسجّل بيتعمله Profile غير Active (ميشوفش ولا يعمل أي حاجة) لحد ما Admin أو Manager يأكده ويدّيله صلاحياته.
--  * الـ Manager يقدر يوافق على المستخدمين المعلقين (وعلى Viewer / Kitchen User اللي معاه في نفس المطبخ) بحدود:
--      - الدور Viewer أو Kitchen User بس
--      - مطابخه وصفحاته هو بس (مينفعش يدّي أكتر من اللي معاه)
--      - مبيلمسش مطابخ/صفحات المستخدم اللي برا نطاقه
--    الـ Admin بيفضل صاحب الصلاحية الكاملة (والـ Root محمي زي ما هو).
-- =====================================================================

-- 1) شيل تقييد الدومين
drop trigger if exists auth_users_email_domain on auth.users;
drop function if exists public.enforce_email_domain();

-- 2) مين يقدر المدير يديره: المعلقين + Viewer/Kitchen User اللي شايفين مطبخ مشترك معاه
create function public.can_manage_user(p_target uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select case
    when public.is_admin() then true
    when public.my_role() is distinct from 'manager' then false
    else exists (
      select 1 from public.profiles t
       where t.user_id = p_target and not t.is_root and t.role in ('viewer', 'kitchen_user')
         and (not t.is_active or exists (
               select 1 from public.user_kitchens tk join public.user_kitchens mk on mk.kitchen_id = tk.kitchen_id
                where tk.user_id = t.user_id and mk.user_id = auth.uid())))
  end
$$;

drop policy profiles_read on public.profiles;
create policy profiles_read on public.profiles for select to authenticated
  using (user_id = auth.uid() or public.is_admin() or public.can_manage_user(user_id));
drop policy user_kitchens_read on public.user_kitchens;
create policy user_kitchens_read on public.user_kitchens for select to authenticated
  using (user_id = auth.uid() or public.is_admin() or public.can_manage_user(user_id));
drop policy user_pages_read on public.user_pages;
create policy user_pages_read on public.user_pages for select to authenticated
  using (user_id = auth.uid() or public.is_admin() or public.can_manage_user(user_id));

-- 3) set_user_access: Admin كامل، Manager بحدود
create or replace function public.set_user_access(
  p_user uuid, p_role text, p_active boolean, p_kitchens uuid[], p_pages text[]
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_admin boolean := public.is_admin();
  v_mgr   boolean := coalesce(public.my_role() = 'manager', false);   -- coalesce: المستخدم غير الفعّال my_role() بتاعه null ولازم يترفض
  my_k uuid[] := '{}'; my_p text[] := '{}';
begin
  if not (v_admin or v_mgr) then raise exception 'للـ Admin أو الـ Manager بس'; end if;

  if v_mgr then
    if not public.can_manage_user(p_user) then
      raise exception 'المستخدم ده مش في نطاقك — تقدر تدير المستخدمين المعلقين واللي معاك في نفس المطبخ (Viewer / Kitchen User) بس';
    end if;
    if p_role not in ('viewer', 'kitchen_user') then
      raise exception 'الـ Manager يقدر يدّي دور Viewer أو Kitchen User بس';
    end if;
    select coalesce(array_agg(kitchen_id), '{}') into my_k from public.user_kitchens where user_id = auth.uid();
    select coalesce(array_agg(page_key), '{}') into my_p from public.user_pages where user_id = auth.uid();
    if exists (select 1 from unnest(coalesce(p_kitchens, '{}')) k where k <> all (my_k)) then
      raise exception 'مينفعش تدّي مطبخ مش من مطابخك';
    end if;
    if exists (select 1 from unnest(coalesce(p_pages, '{}')) pg where pg <> all (my_p)) then
      raise exception 'مينفعش تدّي صفحة مش من صفحاتك';
    end if;
  end if;

  update public.profiles set role = p_role::public.app_role, is_active = p_active where user_id = p_user;
  if not found then raise exception 'المستخدم مش موجود'; end if;

  -- الـ Admin بيستبدل الكل، والـ Manager بيلمس نطاقه بس
  delete from public.user_kitchens
   where user_id = p_user and not (kitchen_id = any (coalesce(p_kitchens, '{}'))) and (v_admin or kitchen_id = any (my_k));
  insert into public.user_kitchens (user_id, kitchen_id)
    select p_user, k from unnest(coalesce(p_kitchens, '{}')) k
    where exists (select 1 from public.kitchens where id = k)
  on conflict do nothing;

  delete from public.user_pages
   where user_id = p_user and not (page_key = any (coalesce(p_pages, '{}'))) and (v_admin or page_key = any (my_p));
  insert into public.user_pages (user_id, page_key)
    select p_user, pg from unnest(coalesce(p_pages, '{}')) pg
    where pg <> 'access_control' and exists (select 1 from public.pages where key = pg)
  on conflict do nothing;
end $$;

-- 4) الدعوة المسبقة: أي إيميل (مش شرط breadfast)
create or replace function public.invite_user(
  p_email text, p_role text, p_active boolean, p_kitchens uuid[], p_pages text[]
) returns void
language plpgsql security definer set search_path = public as $$
declare v_email text := lower(btrim(p_email));
begin
  if not public.is_admin() then raise exception 'للـ Admin بس'; end if;
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'الإيميل مش صحيح'; end if;
  if exists (select 1 from public.profiles where lower(email) = v_email) then
    raise exception 'المستخدم ده موجود بالفعل — عدّل صلاحياته من الجدول';
  end if;
  insert into public.access_invites (email, role, is_active, kitchen_ids, page_keys, created_by)
  values (v_email, p_role::public.app_role, p_active, coalesce(p_kitchens, '{}'),
          array(select pg from unnest(coalesce(p_pages, '{}')) pg where pg <> 'access_control'), auth.uid())
  on conflict (email) do update
    set role = excluded.role, is_active = excluded.is_active,
        kitchen_ids = excluded.kitchen_ids, page_keys = excluded.page_keys;
end $$;

-- 5) Dashboard: عدد المستخدمين المعلقين للـ Admin والـ Manager
create or replace function public.dashboard_summary(p_kitchen uuid) returns jsonb
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
    'pending_users', case when public.my_role() in ('admin', 'manager') then (select count(*) from public.profiles where not is_active and role in ('viewer', 'kitchen_user')) else null end,
    'top_products', coalesce((select jsonb_agg(t) from (
        select p.syt_code, p.name as product_name, b.qty_base as qty, p.uom_factor, round(b.qty_base * p.cost_per_uom, 2) as value
          from public.stock_balances b join public.products p on p.id = b.product_id
         where b.kitchen_id = p_kitchen and b.location = 'WAREHOUSE' and b.qty_base > 0
         order by b.qty_base * p.cost_per_uom desc limit 8) t), '[]'::jsonb)
  ) into v_res;
  return v_res;
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

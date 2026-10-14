-- =====================================================================
-- KMS batch 7.4 / 015
--  قفل فترة اتفتحت قبل كده (Reopen) كان بيفشل برسالة "بتتداخل مع فترة مقفولة" لأن صف الفترة بيفضل OPEN.
--  دلوقتي close_period بيقفل الصف المفتوح نفسه، ويضيف صفوف جديدة للأيام اللي ملهاش فترة.
-- =====================================================================

create or replace function public.close_period(p_kitchen uuid, p_from date, p_to date) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_first uuid; v_id uuid; r record; v_run record;
begin
  if not (public.my_role() in ('admin', 'manager') and public.has_kitchen(p_kitchen)) then
    raise exception 'قفل الفترة للـ Admin أو الـ Manager على مطابخه';
  end if;
  if p_from is null or p_to is null or p_from > p_to then raise exception 'الفترة غير صحيحة'; end if;
  if p_from <> date_trunc('month', p_from)::date
     or p_to <> (date_trunc('month', p_to) + interval '1 month - 1 day')::date then
    raise exception 'قفل الفترة بشهور كاملة بس — من أول يوم في الشهر لآخر يوم في الشهر';
  end if;

  -- فترة مقفولة بالفعل بتتداخل
  select from_date, to_date into r from public.periods
   where kitchen_id = p_kitchen and status = 'CLOSED' and daterange(from_date, to_date, '[]') && daterange(p_from, p_to, '[]') limit 1;
  if found then
    raise exception 'الفترة دي بتتداخل مع فترة مقفولة قبل كده (% → %)', r.from_date, r.to_date;
  end if;

  -- فترة مفتوحة (اتفتحت بـ Reopen) بتتخطى حدود الفترة المطلوبة
  select from_date, to_date into r from public.periods
   where kitchen_id = p_kitchen and status = 'OPEN'
     and daterange(from_date, to_date, '[]') && daterange(p_from, p_to, '[]')
     and (from_date < p_from or to_date > p_to) limit 1;
  if found then
    raise exception 'فيه فترة مفتوحة (% → %) بتتخطى الفترة المطلوبة — اقفلها بنفس حدودها', r.from_date, r.to_date;
  end if;

  -- الفترات المفتوحة اللي جوه المطلوب: نقفلها هي نفسها
  for r in select id from public.periods
            where kitchen_id = p_kitchen and status = 'OPEN' and from_date >= p_from and to_date <= p_to order by from_date loop
    update public.periods set status = 'CLOSED', closed_by = auth.uid(), closed_at = now(), reopen_reason = null where id = r.id;
    v_first := coalesce(v_first, r.id);
  end loop;

  -- الأيام اللي لسه ملهاش أي فترة: صفوف جديدة
  for v_run in
    select min(x.d) as f, max(x.d) as t from (
      select g.d::date as d, g.d::date - (row_number() over (order by g.d))::int as grp
        from generate_series(p_from, p_to, interval '1 day') g(d)
       where not exists (select 1 from public.periods o where o.kitchen_id = p_kitchen and g.d::date between o.from_date and o.to_date)) x
     group by x.grp
  loop
    insert into public.periods (kitchen_id, from_date, to_date, status, closed_by, closed_at)
    values (p_kitchen, v_run.f, v_run.t, 'CLOSED', auth.uid(), now())
    returning id into v_id;
    v_first := coalesce(v_first, v_id);
  end loop;
  return v_first;
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

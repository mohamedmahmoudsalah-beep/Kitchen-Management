-- بيحاكي الحد الأدنى من Supabase (auth schema + roles) لاختبار الـ migrations على Postgres عادي.
-- مش بيتشغل على Supabase الحقيقي.
create role anon nologin;
create role authenticated nologin;
create role service_role nologin bypassrls;

create schema auth;
create table auth.users (
  id                uuid primary key default gen_random_uuid(),
  email             text,
  raw_user_meta_data jsonb not null default '{}',
  raw_app_meta_data  jsonb not null default '{}'
);
create function auth.uid() returns uuid language sql stable as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
$$;

grant usage on schema public to anon, authenticated;
grant usage on schema auth to anon, authenticated;
-- زي Supabase: default privileges بتدّي صلاحيات واسعة، والـ migration 004 هي اللي بتشددها
alter default privileges in schema public grant all on tables to anon, authenticated;
alter default privileges in schema public grant all on sequences to anon, authenticated;
alter default privileges in schema public grant execute on functions to anon, authenticated;

import { cache } from 'react';
import { redirect } from 'next/navigation';
import { createClient } from '@/lib/supabase/server';
import type { Kitchen, PageDef, Profile } from '@/lib/types';

export type Session = {
  email: string;
  profile: Profile;
  kitchens: Kitchen[];
  pages: PageDef[]; // الصفحات المسموحة للمستخدم
};

// بيجيب جلسة المستخدم الفعّال (أو بيحوّله لـ login / pending)
export const getSession = cache(async (): Promise<Session> => {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect('/login');

  const { data: profile } = await supabase
    .from('profiles').select('user_id,email,full_name,role,is_active,is_root')
    .eq('user_id', user.id).maybeSingle();
  if (!profile || !profile.is_active) redirect('/pending');

  const [{ data: kitchens }, { data: pages }, { data: up }] = await Promise.all([
    supabase.from('kitchens').select('id,code,name').order('name'),
    supabase.from('pages').select('key,title,sort').order('sort'),
    supabase.from('user_pages').select('page_key').eq('user_id', user.id),
  ]);

  const allowed = new Set((up ?? []).map((r) => r.page_key));
  const isAdmin = profile.role === 'admin';
  return {
    email: user.email ?? profile.email,
    profile: profile as Profile,
    kitchens: (kitchens ?? []) as Kitchen[],
    pages: ((pages ?? []) as PageDef[]).filter((p) => (isAdmin ? true : p.key !== 'access_control' && allowed.has(p.key))),
  };
});

export async function requirePage(key: string): Promise<Session> {
  const s = await getSession();
  if (!s.pages.some((p) => p.key === key)) redirect('/no-access');
  return s;
}

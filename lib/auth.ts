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

type RawSession = { profile: Profile | null; kitchens?: Kitchen[]; pages?: PageDef[]; allowed?: string[] };

// الصفحات المسموحة: Access Control: للـ Admin كامل وللـ Manager (موافقة المستخدمين بحدود)
export function allowedPages(profile: Profile, pages: PageDef[], allowed: string[]): PageDef[] {
  const set = new Set(allowed);
  const isAdmin = profile.role === 'admin';
  return pages.filter((p) => (isAdmin ? true : p.key === 'access_control' ? profile.role === 'manager' : set.has(p.key)));
}

// بيجيب جلسة المستخدم الفعّال (أو بيحوّله لـ login / pending).
// التوكن بيتفحص محليًا (getClaims) والباقي طلب واحد للداتا بيز (my_session) بدل 4 طلبات متتالية.
export const getSession = cache(async (): Promise<Session> => {
  const supabase = await createClient();
  const { data: auth } = await supabase.auth.getClaims();
  const claims = auth?.claims;
  if (!claims?.sub) redirect('/login');

  const { data, error } = await supabase.rpc('my_session');
  const s = data as RawSession | null;
  if (error || !s?.profile || !s.profile.is_active) redirect('/pending');

  return {
    email: (typeof claims.email === 'string' && claims.email) || s.profile.email,
    profile: s.profile,
    kitchens: s.kitchens ?? [],
    pages: allowedPages(s.profile, s.pages ?? [], s.allowed ?? []),
  };
});

export async function requirePage(key: string): Promise<Session> {
  const s = await getSession();
  if (!s.pages.some((p) => p.key === key)) redirect('/no-access');
  return s;
}

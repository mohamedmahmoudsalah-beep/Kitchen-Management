import { NextResponse } from 'next/server';
import { createClient } from '@/lib/supabase/server';

function toLogin(origin: string, error: string, description?: string | null) {
  const u = new URL('/login', origin);
  u.searchParams.set('error', error);
  if (description) u.searchParams.set('error_description', description);
  return NextResponse.redirect(u);
}

export async function GET(request: Request) {
  const { searchParams, origin } = new URL(request.url);

  // Supabase/Google بيرجّعوا الخطأ هنا لو الدخول فشل (مثلًا: Database error saving new user)
  const providerError = searchParams.get('error');
  if (providerError) return toLogin(origin, providerError, searchParams.get('error_description'));

  const code = searchParams.get('code');
  if (!code) return toLogin(origin, 'missing_code', 'مفيش code في رابط الرجوع من جوجل');

  try {
    const supabase = await createClient();
    const { error } = await supabase.auth.exchangeCodeForSession(code);
    if (error) return toLogin(origin, 'exchange_failed', error.message);
  } catch (e) {
    return toLogin(origin, 'exchange_failed', e instanceof Error ? e.message : 'exchange failed');
  }
  return NextResponse.redirect(`${origin}/`);
}

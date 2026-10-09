import { createServerClient } from '@supabase/ssr';
import { NextResponse, type NextRequest } from 'next/server';

const PUBLIC_PATHS = ['/login', '/auth'];

export async function updateSession(request: NextRequest) {
  let response = NextResponse.next({ request });
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY ?? process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY;
  if (!url || !key) return response;

  const supabase = createServerClient(url, key, {
    cookies: {
      getAll: () => request.cookies.getAll(),
      setAll(list) {
        list.forEach(({ name, value }) => request.cookies.set(name, value));
        response = NextResponse.next({ request });
        list.forEach(({ name, value, options }) => response.cookies.set(name, value, options));
      },
    },
  });

  const { data: { user } } = await supabase.auth.getUser();
  const path = request.nextUrl.pathname;
  const isPublic = PUBLIC_PATHS.some((p) => path === p || path.startsWith(p + '/'));

  if (!user && !isPublic) {
    const params = request.nextUrl.searchParams;
    const redirect = request.nextUrl.clone();

    // لو Supabase رجّع الـ code على أي مسار تاني (Site URL مش مظبوط)، كمّل عملية الدخول
    if (params.get('code')) {
      redirect.pathname = '/auth/callback';
      return NextResponse.redirect(redirect);
    }

    // احتفظ برسالة الخطأ عشان تظهر في صفحة الـ Login (مكانتش بتظهر قبل كده)
    redirect.pathname = '/login';
    redirect.search = '';
    for (const k of ['error', 'error_code', 'error_description']) {
      const v = params.get(k);
      if (v) redirect.searchParams.set(k, v);
    }
    return NextResponse.redirect(redirect);
  }
  return response;
}

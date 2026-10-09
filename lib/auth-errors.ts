// بيحوّل أخطاء تسجيل الدخول (من Supabase/Google) لرسالة مفهومة بالعربي
export function explainAuthError(error?: string | null, description?: string | null): { title: string; hint: string } | null {
  const raw = `${error ?? ''} ${description ?? ''}`.trim();
  if (!raw) return null;
  const t = raw.toLowerCase();
  if (t.includes('database error saving new user')) {
    return {
      title: 'مقدرناش نسجّل الحساب',
      hint: 'فشل إنشاء الـ Profile في الداتا بيز. غالبًا migrations ناقصة (لازم 001 لحد 008 بالترتيب) أو فيها خطأ — راجع Supabase ← Logs ← Postgres.',
    };
  }
  if (t.includes('code verifier') || t.includes('pkce') || t.includes('auth code')) {
    return {
      title: 'الجلسة اتقطعت في نص الدخول',
      hint: 'افتح الموقع من نفس الرابط اللي بدأت منه (من غير www أو رابط preview) وجرّب تاني. وتأكد إن المتصفح مش بيمنع الـ cookies.',
    };
  }
  if (t.includes('redirect') && (t.includes('mismatch') || t.includes('not allowed') || t.includes('invalid'))) {
    return { title: 'رابط الرجوع مش متسجل', hint: 'ضيف رابط الموقع /auth/callback في Supabase ← Authentication ← URL Configuration ← Redirect URLs.' };
  }
  if (t.includes('access_denied') || t.includes('access denied')) {
    return { title: 'جوجل رفض الدخول', hint: 'لو الـ OAuth consent screen في وضع Testing لازم تضيف إيميلك في Test users.' };
  }
  if (t.includes('invalid api key') || t.includes('apikey')) {
    return { title: 'مفتاح Supabase غلط', hint: 'في Vercel لازم NEXT_PUBLIC_SUPABASE_ANON_KEY يكون الـ anon/publishable key (مش الـ secret/service_role)، وبعد التعديل اعمل Redeploy.' };
  }
  return { title: 'حصلت مشكلة في تسجيل الدخول', hint: 'ابعت نص الخطأ اللي تحت للدعم.' };
}

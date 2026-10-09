'use client';
import { useEffect, useState } from 'react';
import { createClient } from '@/lib/supabase/client';
import { explainAuthError } from '@/lib/auth-errors';

export default function LoginPage() {
  const [err, setErr] = useState<string | null>(null);
  const [problem, setProblem] = useState<{ title: string; hint: string; raw: string } | null>(null);
  const [busy, setBusy] = useState(false);

  // رسالة الخطأ اللي راجعة من Supabase / الـ callback
  useEffect(() => {
    const p = new URLSearchParams(window.location.search);
    const error = p.get('error');
    const description = p.get('error_description');
    const info = explainAuthError(error, description);
    if (info) setProblem({ ...info, raw: [error, description].filter(Boolean).join(' — ') });
  }, []);

  async function signIn() {
    setBusy(true); setErr(null);
    const supabase = createClient();
    const { error } = await supabase.auth.signInWithOAuth({
      provider: 'google',
      options: {
        redirectTo: `${window.location.origin}/auth/callback`,
        // أي حساب جوجل يقدر يسجّل، لكن مبيدخلش قبل موافقة Admin/Manager
        queryParams: { prompt: 'select_account' },
      },
    });
    if (error) { setErr(error.message); setBusy(false); }
  }

  return (
    <div className="login-wrap">
      <div className="login-card">
        <div className="logo">K</div>
        <h1>Kitchen Management System</h1>
        <p className="muted" style={{ margin: 0 }}>Sign in with your Google account</p>
        {problem && (
          <div className="alert err" style={{ marginTop: 14, textAlign: 'start' }} dir="auto">
            <b>{problem.title}</b>
            <div>{problem.hint}</div>
            <div className="mono" style={{ marginTop: 6, opacity: 0.8, wordBreak: 'break-word' }} dir="ltr">{problem.raw}</div>
          </div>
        )}
        <button className="btn" onClick={signIn} disabled={busy}>{busy ? 'Redirecting…' : 'Continue with Google'}</button>
        {err && <div className="alert err" style={{ marginTop: 14 }} dir="auto">{err}</div>}
      </div>
    </div>
  );
}

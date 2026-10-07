'use client';
import { useState } from 'react';
import { createClient } from '@/lib/supabase/client';

export default function LoginPage() {
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  async function signIn() {
    setBusy(true); setErr(null);
    const supabase = createClient();
    const { error } = await supabase.auth.signInWithOAuth({
      provider: 'google',
      options: {
        redirectTo: `${window.location.origin}/auth/callback`,
        // hd = تلميح بس في واجهة جوجل؛ التقييد الحقيقي في الـ DB (Trigger على auth.users)
        queryParams: { hd: 'breadfast.com', prompt: 'select_account' },
      },
    });
    if (error) { setErr(error.message); setBusy(false); }
  }

  return (
    <div className="login-wrap">
      <div className="login-card">
        <div className="logo">K</div>
        <h1>Kitchen Management System</h1>
        <p className="muted" style={{ margin: 0 }}>Sign in with your Breadfast Google account</p>
        <button className="btn" onClick={signIn} disabled={busy}>{busy ? 'Redirecting…' : 'Continue with Google'}</button>
        {err && <div className="alert err" style={{ marginTop: 14 }} dir="auto">{err}</div>}
      </div>
    </div>
  );
}

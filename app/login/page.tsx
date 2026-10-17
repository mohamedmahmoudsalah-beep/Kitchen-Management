'use client';
import { useEffect, useState } from 'react';
import { createClient } from '@/lib/supabase/client';
import { explainAuthError } from '@/lib/auth-errors';
import './login.css';

// صفحة الدخول (تصميم breadfast-kitchen-portal). الدخول بحساب جوجل بس، ومبيدخلش قبل موافقة Admin/Manager.
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
    if (info) setProblem({ ...info, raw: [error, description].filter(Boolean).join(' — ').slice(0, 300) });
  }, []);

  // الصفحة غامقة: خلفية الـ body نفسها تبقى غامقة هنا بس (عشان الـ overscroll ميظهرش أبيض)، وترجع زي ما كانت لما تسيب الصفحة
  useEffect(() => {
    const prev = document.body.style.background;
    document.body.style.background = '#080b24';
    return () => { document.body.style.background = prev; };
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
    <main className="kp-portal-shell">
      <section className="kp-login-pane" aria-labelledby="kp-login-title">
        <div className="kp-ambient kp-ambient-one" aria-hidden="true" />
        <div className="kp-ambient kp-ambient-two" aria-hidden="true" />

        <header className="kp-brand-lockup">
          <div className="kp-brand-mark-wrap">
            {/* eslint-disable-next-line @next/next/no-img-element */}
            <img className="kp-brand-mark" src="/login/breadfast-logo.jpg" alt="Breadfast logo" width={53} height={53} />
          </div>
          <div className="kp-brand-wording">
            <span className="kp-brand-name">Breadfast</span>
            <span className="kp-brand-tagline">BETTER FOOD <i aria-hidden="true">•</i> BRIGHTER DAYS</span>
          </div>
        </header>

        <div className="kp-login-content">
          <div className="kp-eyebrow"><span className="kp-eyebrow-dot" /> KITCHEN OPERATIONS</div>
          <h1 id="kp-login-title">Welcome <span>back.</span></h1>
          <p className="kp-intro-copy">Your kitchens, in sync. Sign in with your Google account to continue.</p>

          {problem && (
            <div className="kp-notice" role="alert" dir="auto">
              <b>{problem.title}</b>
              <div>{problem.hint}</div>
              <code dir="ltr">{problem.raw}</code>
            </div>
          )}
          {err && <div className="kp-notice" role="alert" dir="auto">{err}</div>}

          <button className="kp-login-button" type="button" onClick={signIn} disabled={busy} aria-busy={busy}>
            {busy ? (
              <><span className="kp-spinner" aria-hidden="true" /><span>Redirecting to Google…</span></>
            ) : (
              <>
                <span>Continue with Google</span>
                <svg viewBox="0 0 24 24" fill="none" aria-hidden="true"><path d="M4 12h15M13 5l7 7-7 7" /></svg>
              </>
            )}
          </button>

          <div className="kp-secure-line">
            <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 3 19 6v5.2c0 4.5-2.8 7.8-7 9.8-4.2-2-7-5.3-7-9.8V6l7-3Z" /><path d="m9 12 2 2 4-4" /></svg>
            <span>Secure Google sign-in. New here? An admin approves your access after your first sign-in.</span>
          </div>
          <p className="kp-ar-note" dir="rtl">أول مرة؟ سجّل دخول بحساب جوجل وانتظر موافقة الـ Admin أو المدير.</p>

          <div className="kp-access-note"><span className="kp-access-note-line" /><span>For authorized Breadfast team members</span></div>
        </div>

        <footer className="kp-login-footer">
          <span>© <span suppressHydrationWarning>{new Date().getFullYear()}</span> Breadfast</span>
          <span className="kp-footer-separator">·</span>
          <span>Kitchen Management System</span>
          <span className="kp-footer-spacer" />
          <span className="kp-status-pill"><span /> Secure sign-in</span>
        </footer>
      </section>

      <aside className="kp-visual-pane" aria-label="Breadfast headquarters at night">
        <div className="kp-building-photo" role="img" aria-label="Night view of the Breadfast headquarters" />
        <div className="kp-photo-vignette" aria-hidden="true" />
        <div className="kp-visual-topline"><span className="kp-topline-rule" /><span>ONE TEAM. BETTER EVERY DAY.</span></div>

        <div className="kp-visual-copy">
          <div className="kp-location-chip"><span className="kp-chip-pulse" /> BUILT AROUND BETTER FOOD</div>
          <h2>Good food.<br /><span>Great work.</span></h2>
          <p>Bringing every kitchen shift together — with care, quality, and a little Breadfast energy.</p>
          <div className="kp-visual-divider"><span /><span /><span /></div>
        </div>

        <div className="kp-floating-badge kp-badge-quality" aria-hidden="true">
          <span className="kp-badge-icon"><svg viewBox="0 0 24 24" fill="none"><path d="M5 4v6M8 4v6M5 7h3M6.5 10v10M16 4c-2 2-2.2 6.5 1 8v8M17 4v8" /></svg></span>
          <span><b>QUALITY</b><small>Every detail matters</small></span>
        </div>
        <div className="kp-floating-badge kp-badge-team" aria-hidden="true">
          <span className="kp-badge-icon"><svg viewBox="0 0 24 24" fill="none"><circle cx="9" cy="8" r="3" /><path d="M3.5 19c.4-3.1 2.2-4.8 5.5-4.8s5.1 1.7 5.5 4.8M16 5.5a3 3 0 0 1 0 5.8M17 14c2.4.5 3.6 2.1 3.8 4.6" /></svg></span>
          <span><b>ONE TEAM</b><small>One shared purpose</small></span>
        </div>

        <div className="kp-visual-bottomline"><span className="kp-bottom-brand-dot" /><span>MADE FOR THE PEOPLE BEHIND THE FOOD</span><span className="kp-bottom-line" /></div>
        <div className="kp-orbit kp-orbit-one" aria-hidden="true" />
        <div className="kp-orbit kp-orbit-two" aria-hidden="true" />
      </aside>
    </main>
  );
}

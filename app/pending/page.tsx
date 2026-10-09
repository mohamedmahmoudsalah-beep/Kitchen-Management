import { redirect } from 'next/navigation';
import { createClient } from '@/lib/supabase/server';
import SignOutButton from '@/components/SignOutButton';

export default async function PendingPage() {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect('/login');
  const { data: profile } = await supabase.from('profiles').select('is_active').eq('user_id', user.id).maybeSingle();
  if (profile?.is_active) redirect('/');

  return (
    <div className="login-wrap">
      <div className="login-card">
        <div className="logo">K</div>
        <h1>Waiting for activation</h1>
        <p className="muted" dir="auto">
          حسابك ({user.email}) اتسجل، بس لسه مستني الـ Admin أو المدير يوافق عليه ويديك المطابخ والصفحات. هتقدر تدخل أول ما يتأكد.
        </p>
        <SignOutButton className="btn secondary" label="Sign out" />
      </div>
    </div>
  );
}

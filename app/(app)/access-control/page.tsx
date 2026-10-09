import AccessView from '@/components/AccessView';
import { requirePage } from '@/lib/auth';

export default async function Page() {
  const s = await requirePage('access_control');
  const role = s.profile.role;
  if (role !== 'admin' && role !== 'manager') return null;
  return <AccessView isAdmin={role === 'admin'} managerPages={s.pages.map((p) => p.key).filter((k) => k !== 'access_control')} />;
}

import AccessView from '@/components/AccessView';
import { requirePage } from '@/lib/auth';

export default async function Page() {
  const s = await requirePage('access_control');
  if (s.profile.role !== 'admin') return null;
  return <AccessView />;
}

import SalesView from '@/components/SalesView';
import { requirePage } from '@/lib/auth';

export default async function SalesPage() {
  const s = await requirePage('sales');
  const role = s.profile.role;
  return <SalesView canWrite={role !== 'viewer'} canManage={role === 'admin' || role === 'manager'} isAdmin={role === 'admin'} />;
}

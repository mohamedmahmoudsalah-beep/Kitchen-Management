import BomView from '@/components/BomView';
import { requirePage } from '@/lib/auth';

export default async function BomPage() {
  const s = await requirePage('bom');
  const role = s.profile.role;
  return <BomView canManage={role === 'admin' || role === 'manager'} />;
}

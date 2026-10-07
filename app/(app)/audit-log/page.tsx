import AuditView from '@/components/AuditView';
import { requirePage } from '@/lib/auth';

export default async function Page() {
  await requirePage('audit_log');
  return <AuditView />;
}

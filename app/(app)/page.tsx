import { redirect } from 'next/navigation';
import DashboardView from '@/components/DashboardView';
import { getSession } from '@/lib/auth';
import { PAGE_HREF } from '@/lib/nav';

export default async function DashboardPage() {
  const s = await getSession();
  if (!s.pages.some((p) => p.key === 'dashboard')) {
    const first = s.pages[0];
    redirect(first ? PAGE_HREF[first.key] : '/no-access');
  }
  return <DashboardView />;
}

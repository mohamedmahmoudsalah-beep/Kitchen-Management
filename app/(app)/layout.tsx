import Shell from '@/components/Shell';
import { getSession } from '@/lib/auth';

export default async function AppLayout({ children }: { children: React.ReactNode }) {
  const s = await getSession();
  return (
    <Shell kitchens={s.kitchens} pages={s.pages} email={s.email}>
      {children}
    </Shell>
  );
}

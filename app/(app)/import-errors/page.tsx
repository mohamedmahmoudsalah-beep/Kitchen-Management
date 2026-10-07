import ImportErrorsView from '@/components/ImportErrorsView';
import { requirePage } from '@/lib/auth';

export default async function Page() {
  await requirePage('import_errors');
  return <ImportErrorsView />;
}

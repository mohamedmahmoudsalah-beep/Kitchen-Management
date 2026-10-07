import { Suspense } from 'react';
import ImportWizard from '@/components/ImportWizard';
import { requirePage } from '@/lib/auth';
import { MODULES, MODULE_ORDER, type ImportModule } from '@/lib/import/columns';

export default async function ImportExportPage() {
  const s = await requirePage('import_export');
  const role = s.profile.role;
  const keys = new Set(s.pages.map((p) => p.key));
  const allowed: ImportModule[] = MODULE_ORDER.filter((m) => {
    if (m === 'products') return (role === 'admin' || role === 'manager') && keys.has('data_product');
    return role !== 'viewer' && keys.has(MODULES[m].page) && s.kitchens.length > 0;
  });

  if (!allowed.length) {
    return <div className="panel" dir="auto"><h2>Import</h2><p className="muted">مفيش موديولات Import متاحة ليك. الـ Admin لازم يدّيك صلاحية صفحات الحركات (مثلًا Opening Balance) ومطبخ.</p></div>;
  }
  return (
    <Suspense fallback={null}>
      <ImportWizard allowed={allowed} isAdmin={role === 'admin'} />
    </Suspense>
  );
}

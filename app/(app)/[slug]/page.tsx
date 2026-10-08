import { notFound } from 'next/navigation';
import DocumentsView from '@/components/DocumentsView';
import PeriodsPanel from '@/components/PeriodsPanel';
import ReasonsPanel from '@/components/ReasonsPanel';
import StockReportView from '@/components/StockReportView';
import TransfersView from '@/components/TransfersView';
import { requirePage } from '@/lib/auth';
import { DOC_TYPE_OF_PAGE, IMPORT_MODULE_OF_PAGE, PAGE_HREF } from '@/lib/nav';

const SLUG_KEYS = ['opening_balance', 'purchases', 'kitchens_transfer', 'warehouse_transactions', 'waste',
  'closing_stock_count', 'consumption', 'warehouse_stock', 'stock_adjustments'];
const SLUG_TO_KEY: Record<string, string> = Object.fromEntries(SLUG_KEYS.map((key) => [PAGE_HREF[key].slice(1), key]));

export function generateStaticParams() {
  return Object.keys(SLUG_TO_KEY).map((slug) => ({ slug }));
}

export default async function Page({ params }: { params: Promise<{ slug: string }> }) {
  const { slug } = await params;
  const key = SLUG_TO_KEY[slug];
  if (!key) notFound();
  const s = await requirePage(key);
  const role = s.profile.role;
  const isAdmin = role === 'admin';
  const canWrite = role !== 'viewer';
  const canReverse = isAdmin || role === 'manager';

  if (key === 'warehouse_stock') return <StockReportView kind="stock" />;
  if (key === 'consumption') return <StockReportView kind="consumption" />;
  const canImport = canWrite && s.pages.some((p) => p.key === 'import_export');
  if (key === 'kitchens_transfer') {
    return <TransfersView canWrite={canWrite} canReverse={canReverse} isAdmin={isAdmin} canImport={canImport}
      canAdjust={canWrite && s.pages.some((p) => p.key === 'stock_adjustments')} />;
  }

  return (
    <>
      {(key === 'waste' || key === 'stock_adjustments') && <ReasonsPanel canAdd={canWrite} isAdmin={isAdmin} />}
      {key === 'closing_stock_count' && <PeriodsPanel canManage={canReverse} isAdmin={isAdmin} />}
      <DocumentsView docType={DOC_TYPE_OF_PAGE[key]} importModule={IMPORT_MODULE_OF_PAGE[key]}
        canWrite={canWrite} canReverse={canReverse} canImport={canImport} isAdmin={isAdmin} manual={key !== 'opening_balance'} />
    </>
  );
}

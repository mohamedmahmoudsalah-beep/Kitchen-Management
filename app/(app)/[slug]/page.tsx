import { notFound } from 'next/navigation';
import DocumentsView from '@/components/DocumentsView';
import ReasonsPanel from '@/components/ReasonsPanel';
import { requirePage } from '@/lib/auth';
import { DOC_TYPE_OF_PAGE, IMPORT_MODULE_OF_PAGE, PAGE_HREF } from '@/lib/nav';

// الصفحات اللي لسه مبنتش (الدفعة 2+) + صفحات الحركات اللي ليها Import دلوقتي
const SLUG_TO_KEY: Record<string, string> = Object.fromEntries(
  Object.entries(PAGE_HREF)
    .filter(([key]) => ['opening_balance', 'purchases', 'kitchens_transfer', 'warehouse_transactions', 'waste',
      'closing_stock_count', 'consumption', 'warehouse_stock', 'stock_adjustments'].includes(key))
    .map(([key, href]) => [href.slice(1), key]),
);

const LATER: Record<string, string> = {
  kitchens_transfer: 'Transfer → In Transit → تأكيد المستلم → Return Pending (الدفعة 2).',
  closing_stock_count: 'جرد الإقفال (Closing) كـ snapshot بيتحسب منه الاستهلاك (الدفعة 2).',
  consumption: 'Consumption = Opening + Purchases + Transfer In − Transfer Out − Closing − Waste، كـ SQL View (الدفعة 2).',
  warehouse_stock: 'Warehouse Stock كـ SQL View من الـ Ledger (الدفعة 2).',
};

export function generateStaticParams() {
  return Object.keys(SLUG_TO_KEY).map((slug) => ({ slug }));
}

export default async function Page({ params }: { params: Promise<{ slug: string }> }) {
  const { slug } = await params;
  const key = SLUG_TO_KEY[slug];
  if (!key) notFound();
  const s = await requirePage(key);

  const docType = DOC_TYPE_OF_PAGE[key];
  if (docType) {
    const role = s.profile.role;
    const canImport = role !== 'viewer' && s.pages.some((p) => p.key === 'import_export');
    return (
      <>
        {(key === 'waste' || key === 'stock_adjustments') && <ReasonsPanel canAdd={role !== 'viewer'} isAdmin={role === 'admin'} />}
        <DocumentsView docType={docType} importModule={IMPORT_MODULE_OF_PAGE[key]}
          canReverse={role === 'admin' || role === 'manager'} canImport={canImport} />
        <div className="alert warn" dir="auto">شاشة الإدخال اليدوي (Draft → Post) هتتضاف في الدفعة 2. دلوقتي الإدخال عن طريق Import from file.</div>
      </>
    );
  }
  return (
    <div className="panel" dir="auto">
      <h2>Coming next</h2>
      <p className="muted">{LATER[key]}</p>
    </div>
  );
}

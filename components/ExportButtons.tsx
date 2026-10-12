'use client';
import { useMemo, useState } from 'react';
import { Download, FileSpreadsheet } from 'lucide-react';
import { createClient } from '@/lib/supabase/client';
import { exportDocuments, type ExportDoc } from '@/lib/doc-export';

// زرارين Export (Excel + CSV) بيطلّعوا صف لكل صنف في المستندات المعروضة
export default function ExportButtons({ docType, docs, loadAll, kitchenName, kitchenNameOf, fileBase }: {
  docType: string; docs: ExportDoc[]; loadAll?: () => Promise<ExportDoc[]>; kitchenName: string; kitchenNameOf?: (id: string | null | undefined) => string; fileBase?: string;
}) {
  const supabase = useMemo(() => createClient(), []);
  const [busy, setBusy] = useState<'csv' | 'xlsx' | null>(null);
  const [err, setErr] = useState<string | null>(null);

  async function run(format: 'csv' | 'xlsx') {
    setBusy(format); setErr(null);
    try { await exportDocuments(supabase, format, docType, loadAll ? await loadAll() : docs, { kitchenName, kitchenNameOf, fileBase }); }
    catch (e) { setErr(e instanceof Error ? e.message : String(e)); }
    setBusy(null);
  }
  return (
    <>
      <button className="btn secondary" disabled={!!busy || !docs.length} onClick={() => run('xlsx')} title="صف لكل صنف — كل المستندات المطابقة للبحث والفترة">
        <FileSpreadsheet size={14} /> {busy === 'xlsx' ? 'Exporting…' : 'Export Excel'}
      </button>
      <button className="btn secondary" disabled={!!busy || !docs.length} onClick={() => run('csv')} title="صف لكل صنف في كل مستند">
        <Download size={14} /> {busy === 'csv' ? 'Exporting…' : 'CSV'}
      </button>
      {err && <span className="badge err" title={err}>Export failed</span>}
    </>
  );
}

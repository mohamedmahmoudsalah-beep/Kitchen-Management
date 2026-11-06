'use client';
import { useEffect, useMemo, useState } from 'react';
import { RefreshCw, Download, Search } from 'lucide-react';
import { createClient } from '@/lib/supabase/client';
import { useScope } from '@/components/ScopeProvider';
import Qty from '@/components/Qty';
import { downloadCsv, downloadXlsx, ymd } from '@/lib/export';
import { fmt } from '@/lib/qty';
import { groupByGeneric, type Grouped } from '@/lib/group-generic';
import { invalidateAll, loadCached } from '@/lib/cache';
import { lastPurchased } from '@/lib/import/ambiguous';
import PdfButton from '@/components/PdfButton';
import { reportPdf } from '@/lib/pdf/documents';

type R = {
  product_id: string; syt_code: string; generic_code: string | null; product_name: string; category: string | null;
  uom_factor: number; cost_per_uom: number;
  opening: number; purchases: number; transfer_in: number; transfer_out: number; waste: number;
  warehouse_txn?: number; adjustments?: number; closing_book?: number; in_transit?: number; return_pending?: number;
  closing?: number; consumption?: number; has_closing?: boolean; closing_date?: string | null;
  sales_rm?: number; sales_consumption?: number; variance?: number;
};

type Col = { key: keyof R; label: string; qty?: boolean; bold?: boolean; title?: string };

const STOCK_COLS: Col[] = [
  { key: 'opening', label: 'Opening', qty: true },
  { key: 'purchases', label: '+ Purchases', qty: true },
  { key: 'transfer_in', label: '+ Transfer In', qty: true, title: 'المستلم فعليًا (Confirmed)' },
  { key: 'transfer_out', label: '− Transfer Out', qty: true, title: 'المرتجع المعلق بيفضل Transfer Out لحد تأكيد رجوعه' },
  { key: 'warehouse_txn', label: '− Warehouse Txn', qty: true, title: 'صفحة Warehouse Transactions اتشالت — العمود بيظهر بس لو فيه حركات قديمة' },
  { key: 'sales_rm', label: '− Sales (BOM)', qty: true, title: 'خصم الـ RM من المبيعات على حسب الـ BOM' },
  { key: 'waste', label: '− Waste', qty: true },
  { key: 'adjustments', label: '± Adjustments', qty: true },
  { key: 'closing_book', label: '= Stock', qty: true, bold: true },
  { key: 'in_transit', label: 'In transit', qty: true, title: 'محوّل من المطبخ ده ولسه ما اتستلمش' },
  { key: 'return_pending', label: 'Return pending', qty: true, title: 'فرق الاستلام المعلق على المطبخ ده' },
];
const CONS_COLS: Col[] = [
  { key: 'opening', label: 'Opening', qty: true },
  { key: 'purchases', label: '+ Purchases', qty: true },
  { key: 'transfer_in', label: '+ Transfer In', qty: true },
  { key: 'transfer_out', label: '− Transfer Out', qty: true },
  { key: 'closing', label: '− Closing (count)', qty: true },
  { key: 'waste', label: '− Waste', qty: true },
  { key: 'consumption', label: '= Actual consumption', qty: true, bold: true, title: 'الاستهلاك الفعلي من الجرد' },
  { key: 'sales_consumption', label: 'From sales (BOM)', qty: true, title: 'الاستهلاك المحسوب من المبيعات × الـ BOM' },
  { key: 'variance', label: 'Variance (actual − sales)', qty: true, bold: true, title: 'موجب = استهلكت أكتر من اللي المبيعات بتقوله · سالب = أقل' },
];

export default function StockReportView({ kind }: { kind: 'stock' | 'consumption' }) {
  const supabase = useMemo(() => createClient(), []);
  const { kitchenId, kitchen, from, to } = useScope();
  const [rows, setRows] = useState<R[]>([]);
  const [loading, setLoading] = useState(true);
  const [err, setErr] = useState<string | null>(null);
  const [q, setQ] = useState('');
  const [pieces, setPieces] = useState(true);
  const [byGeneric, setByGeneric] = useState(true);
  const [lastSyt, setLastSyt] = useState<Record<string, string>>({});
  const baseCols = kind === 'stock' ? STOCK_COLS : CONS_COLS;
  const valueKey: keyof R = kind === 'stock' ? 'closing_book' : 'consumption';
  const cols = useMemo(() => baseCols.filter((c) => c.key !== 'warehouse_txn' || rows.some((r) => Number(r.warehouse_txn ?? 0) !== 0)), [baseCols, rows]);

  const [nonce, setNonce] = useState(0);   // زرار Refresh
  useEffect(() => {
    let alive = true;
    setLoading(true); setErr(null);
    loadCached<R[]>(`rep:${kind}:${kitchenId}:${from}:${to}`, async () => {
      const all: R[] = [];
      for (let f = 0; ; f += 1000) {
        const { data, error } = await supabase
          .rpc(kind === 'stock' ? 'report_warehouse_stock' : 'report_consumption', { p_kitchen: kitchenId, p_from: from, p_to: to })
          .range(f, f + 999);
        if (error) throw new Error(error.message);
        all.push(...((data ?? []) as R[]));
        if (!data || data.length < 1000) break;
      }
      return all;
    }, (d) => { if (alive) { setRows(d); setLoading(false); } })
      .catch((e: Error) => { if (alive) { setErr(e.message); setRows([]); setLoading(false); } });
    return () => { alive = false; };
  }, [supabase, kind, kitchenId, from, to, nonce]);

  // آخر Syt اتشترى لكل Generic (بيحدد اسم الصف المجمّع)
  useEffect(() => {
    if (!byGeneric || !rows.length) return;
    const gens = [...new Set(rows.map((r) => r.generic_code).filter((g): g is string => !!g))];
    let alive = true;
    loadCached<Record<string, string>>(`lastsyt:${kind}:${kitchenId}:${from}:${to}`, async () => {
      const out: Record<string, string> = {};
      for (let i = 0; i < gens.length; i += 300) {
        const res = await lastPurchased(supabase, gens.slice(i, i + 300));
        Object.entries(res).forEach(([code, v]) => { out[code] = v.syt; });
      }
      return out;
    }, (d) => { if (alive) setLastSyt(d); }).catch(() => undefined);
    return () => { alive = false; };
  }, [supabase, byGeneric, rows, kind, kitchenId, from, to]);

  const qtyKeys = useMemo(() => cols.map((c) => c.key as string), [cols]);
  const display: Grouped<R>[] = useMemo(
    () => groupByGeneric(rows, qtyKeys, valueKey as string, byGeneric ? lastSyt : {}, byGeneric),
    [rows, qtyKeys, valueKey, lastSyt, byGeneric],
  );
  const needle = q.trim().toLowerCase();
  const shown = display.filter((r) => !needle || r.search.includes(needle));
  const value = (r: Grouped<R>) => r.value;
  const total = shown.reduce((s, r) => s + value(r), 0);

  const head = ['Syt Code', 'Generic Code', 'Product', 'Category', 'Base Qty per Syt', 'Syt Codes', ...cols.map((c) => c.label), 'Cost Pr UOM (current)', 'Value @ current cost'];
  const exportRows = () => shown.map((r) => [r.grouped ? '' : r.syt_code, r.generic_code, r.product_name, r.category, r.grouped ? '' : Number(r.uom_factor), r.members.join(' | '),
    ...cols.map((c) => Number(r[c.key] ?? 0)), Math.round(Number(r.cost_per_uom) * 10000) / 10000, Math.round(value(r) * 100) / 100]);
  const fileBase = `${kind === 'stock' ? 'warehouse-stock' : 'consumption'}-${kitchen?.code ?? ''}-${from}_${to}`;

  // PDF: نفس الصفوف المعروضة (مجمّعة أو لا)، landscape
  const pdf = () => reportPdf({
    title: kind === 'stock' ? 'Warehouse Stock' : 'Consumption',
    subtitle: `${kitchen?.name ?? ''} · ${from} → ${to}`,
    meta: [['Kitchen', kitchen?.name ?? ''], ['Period', `${from} → ${to}`], ['Products', String(shown.length)], ['Grouped by Generic Code', byGeneric ? 'Yes' : 'No']],
    cols: [{ head: 'Code', w: 11 }, { head: 'Product', w: 30 }, ...cols.map((c) => ({ head: c.label, w: 8.5, align: 'right' as const })), { head: 'Value @ current cost', w: 11, align: 'right' as const }],
    rows: shown.map((r) => [r.syt_code, r.product_name, ...cols.map((c) => fmt(r[c.key] ?? 0)), fmt(value(r), 2)]),
    foot: ['', 'Total value', ...cols.map(() => ''), fmt(total, 2)],
    note: kind === 'consumption' ? 'Quantities are in base units (kg). Actual consumption = Opening + Purchases + Transfer In − Transfer Out − Closing − Waste. Variance = actual − consumption computed from sales (BOM).' : 'Quantities are in base units (kg).',
    fileBase: `${kind === 'stock' ? 'warehouse-stock' : 'consumption'}-${kitchen?.code ?? ''}-${from}_${to}`,
  });

  const first = rows[0];
  const noClosing = kind === 'consumption' && rows.length > 0 && !first?.has_closing;
  const cutoff = kind === 'consumption' && first?.has_closing && first.closing_date && first.closing_date < to ? first.closing_date : null;

  return (
    <div className="panel flush">
      <div className="toolbar">
        <div style={{ position: 'relative' }}>
          <Search size={14} style={{ position: 'absolute', left: 8, top: 9, color: 'var(--muted)' }} />
          <input type="search" value={q} onChange={(e) => setQ(e.target.value)} placeholder="Search product" style={{ paddingLeft: 28, width: 220 }} />
        </div>
        <label className="muted" title="يجمّع كل أكواد السيستم (الأحجام) اللي ليها نفس الـ Generic Code في صف واحد"><input type="checkbox" checked={byGeneric} onChange={(e) => setByGeneric(e.target.checked)} /> Group by Generic Code</label>
        <label className="muted"><input type="checkbox" checked={pieces} onChange={(e) => setPieces(e.target.checked)} /> Show Syt pcs</label>
        <span className="muted" dir="auto">{kitchen?.name} · {from} → {to} · {shown.length} منتج</span>
        <span className="spacer" />
        <button className="btn secondary" title="تحديث البيانات" onClick={() => { invalidateAll(); setNonce((n) => n + 1); }}><RefreshCw size={14} /> Refresh</button>
        <PdfButton label="PDF" title="تحميل PDF بالصفوف المعروضة" disabled={!shown.length} build={pdf} />
        <button className="btn secondary" disabled={!shown.length} onClick={() => downloadCsv(`${fileBase}.csv`, head, exportRows())}><Download size={14} /> CSV</button>
        <button className="btn secondary" disabled={!shown.length} onClick={() => downloadXlsx(`${fileBase}.xlsx`, head, exportRows())}><Download size={14} /> XLSX</button>
      </div>
      {err && <div className="alert err" style={{ margin: 12 }} dir="auto">{err}</div>}
      {noClosing && (
        <div className="alert warn" style={{ margin: 12 }} dir="auto">
          مفيش جرد (Closing) متسجل في الفترة دي، فالـ Closing = 0 والاستهلاك = كل المتاح. سجّل الجرد من صفحة Closing / Stock Count.
        </div>
      )}
      {cutoff && (
        <div className="alert ok" style={{ margin: 12 }} dir="auto">الاستهلاك محسوب لحد تاريخ الجرد ({cutoff}). الحركات بعده مش داخلة.</div>
      )}
      {kind === 'consumption' && rows.length > 0 && (
        <div className="muted" style={{ margin: '8px 14px' }} dir="auto">
          Variance = الاستهلاك الفعلي − الاستهلاك المحسوب من المبيعات. الأدق تسيب Group by Generic Code شغّال (المبيعات بتخصم من Syt واحد لكل Generic، والفعلي موزّع على الأحجام).
        </div>
      )}
      {kind === 'consumption' && first?.has_closing && !cutoff && (
        <div className="muted" style={{ margin: '8px 14px' }} dir="auto">محسوب على جرد بتاريخ {first.closing_date}. المنتج اللي مش في الجرد بيتحسب Closing = 0.</div>
      )}
      <div className="table-wrap">
        <table className="grid">
          <thead><tr>
            <th>Syt Code</th><th>Product</th>
            {cols.map((c) => <th key={c.key} className="num" title={c.title}>{c.label}</th>)}
            <th className="num" title="بسعر الوحدة الأساسية الحالي (مش المتجمّد)">Value @ current cost</th>
          </tr></thead>
          <tbody>
            {shown.map((r) => (
              <tr key={r.product_id}>
                <td className="mono">
                  {r.grouped ? <>{r.generic_code}<div className="muted" title={r.members.join(', ')}>{r.members.length} Syt codes</div></> : <>{r.syt_code}{r.generic_code && <div className="muted">{r.generic_code}</div>}</>}
                </td>
                <td dir="auto">{r.product_name}</td>
                {cols.map((c) => (
                  <td key={c.key} className="num" style={c.bold ? { fontWeight: 700 } : undefined}>
                    {pieces ? <Qty base={Number(r[c.key] ?? 0)} factor={r.uom_factor} /> : fmt(r[c.key])}
                  </td>
                ))}
                <td className="num">{fmt(value(r), 2)}</td>
              </tr>
            ))}
            {!shown.length && <tr><td colSpan={cols.length + 3} className="empty">{loading ? 'Loading…' : 'No data for this branch and period'}</td></tr>}
          </tbody>
          {shown.length > 0 && (
            <tfoot><tr>
              <td colSpan={cols.length + 2} style={{ textAlign: 'right', fontWeight: 600 }}>Total value @ current cost</td>
              <td className="num" style={{ fontWeight: 700 }}>{fmt(total, 2)}</td>
            </tr></tfoot>
          )}
        </table>
      </div>
    </div>
  );
}

'use client';
import { useEffect, useMemo, useState } from 'react';
import { Download } from 'lucide-react';
import { createClient } from '@/lib/supabase/client';
import { useScope } from '@/components/ScopeProvider';
import { downloadXlsx } from '@/lib/export';
import { fmt } from '@/lib/qty';
import { groupByGeneric } from '@/lib/group-generic';

type R = {
  product_id: string; syt_code: string; generic_code: string | null; product_name: string; category: string | null; uom_factor: number; cost_per_uom: number;
  opening: number; purchases: number; transfer_in: number; transfer_out: number; waste: number; closing: number; consumption: number;
  sales_consumption: number; variance: number;
};
type Snap = { id: string; from_date: string; to_date: string; created_at: string };
const KEYS = ['opening', 'purchases', 'transfer_in', 'transfer_out', 'closing', 'waste', 'consumption', 'sales_consumption', 'variance'];
const LABEL: Record<string, string> = { opening: 'Opening', purchases: '+ Purchases', transfer_in: '+ Transfer In', transfer_out: '− Transfer Out', closing: '− Closing', waste: '− Waste',
  consumption: '= Actual', sales_consumption: 'From sales (BOM)', variance: 'Variance' };

// ملخص الاستهلاك اللي اتحفظ وقت قفل كل شهر (فعلي vs المبيعات) — بيفضل موجود حتى بعد مسح المبيعات الخام أو الأرشفة.
export default function SavedConsumption() {
  const supabase = useMemo(() => createClient(), []);
  const { kitchenId, kitchen } = useScope();
  const [snaps, setSnaps] = useState<Snap[]>([]);
  const [sel, setSel] = useState<{ snap: Snap; rows: R[] } | null>(null);
  const [byGeneric, setByGeneric] = useState(true);

  useEffect(() => {
    setSel(null);
    supabase.from('period_snapshots').select('id,from_date,to_date,created_at').eq('kitchen_id', kitchenId).order('from_date', { ascending: false })
      .then(({ data }) => setSnaps((data ?? []) as Snap[]));
  }, [supabase, kitchenId]);

  async function open(s: Snap) {
    const { data } = await supabase.from('period_snapshots').select('consumption').eq('id', s.id).maybeSingle();
    setSel({ snap: s, rows: ((data?.consumption ?? []) as R[]).map((r) => ({ ...r, ...Object.fromEntries(KEYS.map((k) => [k, Number((r as unknown as Record<string, unknown>)[k] ?? 0)])) })) });
  }
  const shown = useMemo(() => (sel ? groupByGeneric(sel.rows, KEYS, 'consumption', {}, byGeneric) : []), [sel, byGeneric]);
  if (!snaps.length) return null;

  return (
    <details className="panel" style={{ padding: '10px 14px', marginTop: 14 }}>
      <summary style={{ cursor: 'pointer', fontWeight: 600 }}>Saved months · {kitchen?.name} ({snaps.length})</summary>
      <div className="muted" style={{ margin: '8px 0' }} dir="auto">الاستهلاك الفعلي مقابل المبيعات زي ما اتحفظ لحظة قفل الشهر.</div>
      <div className="form-row">
        {snaps.map((s) => <button key={s.id} className={`btn small ${sel?.snap.id === s.id ? '' : 'secondary'}`} onClick={() => open(s)}>{s.from_date.slice(0, 7)}</button>)}
        {sel && <label className="muted"><input type="checkbox" checked={byGeneric} onChange={(e) => setByGeneric(e.target.checked)} /> Group by Generic Code</label>}
        <span className="spacer" />
        {sel && <button className="btn secondary small" onClick={() => downloadXlsx(`consumption-saved-${kitchen?.code ?? ''}-${sel.snap.from_date.slice(0, 7)}.xlsx`,
          ['Syt Code', 'Generic Code', 'Product', ...KEYS.map((k) => LABEL[k])],
          shown.map((r) => [r.grouped ? '' : r.syt_code, r.generic_code, r.product_name, ...KEYS.map((k) => Number((r as unknown as Record<string, number>)[k] ?? 0))]))}><Download size={13} /> XLSX</button>}
      </div>
      {sel && (
        <div className="table-wrap" style={{ marginTop: 8 }}>
          <table className="grid">
            <thead><tr><th>Code</th><th>Product</th>{KEYS.map((k) => <th key={k} className="num">{LABEL[k]}</th>)}</tr></thead>
            <tbody>
              {shown.map((r) => (
                <tr key={r.product_id}>
                  <td className="mono">{r.grouped ? r.generic_code : r.syt_code}</td><td dir="auto">{r.product_name}</td>
                  {KEYS.map((k) => <td key={k} className="num" style={k === 'variance' ? { fontWeight: 700 } : undefined}>{fmt((r as unknown as Record<string, number>)[k])}</td>)}
                </tr>
              ))}
              {!shown.length && <tr><td colSpan={KEYS.length + 2} className="empty">No data saved</td></tr>}
            </tbody>
          </table>
        </div>
      )}
    </details>
  );
}

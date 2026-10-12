'use client';
import { useEffect, useMemo, useState } from 'react';
import { Download, FileSpreadsheet } from 'lucide-react';
import { createClient } from '@/lib/supabase/client';
import { useScope } from '@/components/ScopeProvider';
import ProductPicker, { type ProductLite } from '@/components/ProductPicker';
import Qty from '@/components/Qty';
import { downloadCsv, downloadXlsx, ymd } from '@/lib/export';
import { fmt } from '@/lib/qty';

export type CardRow = {
  posting_date: string; at: string; doc_no: string; doc_type: string; doc_status: string; kitchen: string; counterpart: string | null;
  location: string; movement_type: string; is_reversal: boolean; qty_base: number; qty_pieces: number; uom_factor: number;
  unit_cost: number | null; value: number | null; balance_after: number | null; reason: string | null; note: string | null; user_email: string | null;
};

export const MOVE_LABEL: Record<string, string> = {
  OPENING: 'Opening', PURCHASE: 'Purchase', TRANSFER_OUT: 'Transfer out', TRANSFER_IN: 'Transfer in', TRANSFER_RETURN_IN: 'Return received',
  WH_TXN: 'Warehouse txn', WASTE: 'Waste', ADJ_PLUS: 'Adjustment +', ADJ_MINUS: 'Adjustment −', TRANSIT_IN: 'In transit (+)',
  TRANSIT_OUT: 'In transit (−)', RETURN_HOLD_IN: 'Return pending (+)', RETURN_HOLD_OUT: 'Return pending (−)', CLOSING_COUNT: 'Closing count',
};
const LOC: Record<string, string> = { WAREHOUSE: 'Warehouse', IN_TRANSIT: 'In transit', RETURN_PENDING: 'Return pending' };

export function cardTable(rows: CardRow[]) {
  return {
    headers: ['Date', 'Doc No', 'Doc type', 'Doc status', 'Kitchen', 'Other kitchen', 'Location', 'Movement', 'Reversal', 'Qty (base, ±)', 'Qty (Syt pcs, ±)',
      'Unit cost', 'Value', 'Balance after (warehouse)', 'Reason', 'Note', 'By'],
    rows: rows.map((r) => [r.posting_date, r.doc_no, r.doc_type, r.doc_status, r.kitchen, r.counterpart, LOC[r.location] ?? r.location,
      MOVE_LABEL[r.movement_type] ?? r.movement_type, r.is_reversal ? 'yes' : '', Number(r.qty_base), Number(r.qty_pieces),
      r.unit_cost === null ? null : Number(r.unit_cost), r.value === null ? null : Number(r.value),
      r.balance_after === null ? null : Number(r.balance_after), r.reason, r.note, r.user_email]),
  };
}

export default function ProductCardView() {
  const supabase = useMemo(() => createClient(), []);
  const { kitchenId, kitchen, from, to } = useScope();
  const [product, setProduct] = useState<ProductLite | null>(null);
  const [allKitchens, setAllKitchens] = useState(false);
  const [allDates, setAllDates] = useState(false);
  const [rows, setRows] = useState<CardRow[]>([]);
  const [loading, setLoading] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => {
    if (!product) { setRows([]); return; }
    let alive = true;
    setLoading(true); setErr(null);
    supabase.rpc('product_card', {
      p_product: product.id, p_kitchen: allKitchens ? null : kitchenId, p_from: allDates ? null : from, p_to: allDates ? null : to,
    }).then(({ data, error }) => {
      if (!alive) return;
      if (error) setErr(error.message); else setRows((data ?? []) as CardRow[]);
      setLoading(false);
    });
    return () => { alive = false; };
  }, [supabase, product, kitchenId, from, to, allKitchens, allDates]);

  const f = Number(product?.uom_factor ?? 1);
  const wh = rows.filter((r) => r.location === 'WAREHOUSE' && r.movement_type !== 'CLOSING_COUNT');
  const inn = wh.filter((r) => r.qty_base > 0).reduce((a, r) => a + Number(r.qty_base), 0);
  const out = wh.filter((r) => r.qty_base < 0).reduce((a, r) => a + Number(r.qty_base), 0);
  const file = `product-card-${product?.syt_code ?? ''}-${ymd(new Date())}`;
  const t = cardTable(rows);

  return (
    <div className="panel flush">
      <div className="toolbar">
        <div style={{ minWidth: 300 }}><ProductPicker value={product} onChange={setProduct} /></div>
        <label className="checks"><span><input type="checkbox" checked={allKitchens} onChange={(e) => setAllKitchens(e.target.checked)} /> All my kitchens (not only {kitchen?.name})</span></label>
        <label className="checks"><span><input type="checkbox" checked={allDates} onChange={(e) => setAllDates(e.target.checked)} /> All dates</span></label>
        <span className="spacer" />
        <button className="btn secondary" disabled={!rows.length} onClick={() => downloadXlsx(`${file}.xlsx`, t.headers, t.rows)}><FileSpreadsheet size={14} /> Excel</button>
        <button className="btn secondary" disabled={!rows.length} onClick={() => downloadCsv(`${file}.csv`, t.headers, t.rows)}><Download size={14} /> CSV</button>
      </div>
      {err && <div className="alert err" style={{ margin: 12 }}>{err}</div>}
      {!product ? <div className="empty muted" style={{ padding: 28, textAlign: 'center' }} dir="auto">اختار منتج (بالكود أو الاسم) عشان تشوف كل حركة حصلت عليه: زيادة أو نقص، بكام كمية، ومين عملها.</div> : (
        <>
          <div className="cards" style={{ padding: 12 }}>
            <div className="card"><div className="k">Total in (warehouse)</div><div className="v" style={{ color: 'var(--ok)' }}>+{fmt(inn)}</div><div className="muted">{fmt(inn / f)} Syt pcs</div></div>
            <div className="card"><div className="k">Total out (warehouse)</div><div className="v" style={{ color: 'var(--err)' }}>{fmt(out)}</div><div className="muted">{fmt(out / f)} Syt pcs</div></div>
            <div className="card"><div className="k">Net</div><div className="v">{fmt(inn + out)}</div><div className="muted">{rows.length} حركة</div></div>
          </div>
          <div className="table-wrap">
            <table className="grid">
              <thead><tr><th>Date</th><th>Doc No</th><th>Movement</th><th>Kitchen</th><th>Effect</th><th className="num">Qty</th><th className="num">Balance after</th><th>Reason / Note</th><th>By</th></tr></thead>
              <tbody>
                {rows.map((r, i) => {
                  const cnt = r.movement_type === 'CLOSING_COUNT';
                  return (
                    <tr key={i}>
                      <td className="mono" style={{ whiteSpace: 'nowrap' }}>{r.posting_date}<div className="muted" style={{ fontSize: '.8em' }}>{new Date(r.at).toLocaleTimeString()}</div></td>
                      <td className="mono">{r.doc_no}{r.is_reversal && <span className="badge err" style={{ marginLeft: 4 }}>reversal</span>}{r.doc_status === 'REVERSED' && <span className="badge" style={{ marginLeft: 4 }}>reversed</span>}</td>
                      <td>{MOVE_LABEL[r.movement_type] ?? r.movement_type}{r.location !== 'WAREHOUSE' && <div className="muted" style={{ fontSize: '.8em' }}>{LOC[r.location]}</div>}</td>
                      <td>{r.kitchen}{r.counterpart && <span className="muted"> ↔ {r.counterpart}</span>}</td>
                      <td>{cnt ? <span className="badge">Count</span> : <span className={`badge ${r.qty_base > 0 ? 'ok' : 'err'}`}>{r.qty_base > 0 ? '+ Increase' : '− Decrease'}</span>}</td>
                      <td className="num"><Qty base={r.qty_base} factor={r.uom_factor} /></td>
                      <td className="num">{r.balance_after === null ? '—' : <Qty base={r.balance_after} factor={r.uom_factor} />}</td>
                      <td dir="auto" className="muted">{[r.reason, r.note].filter(Boolean).join(' · ')}</td>
                      <td>{r.user_email ?? <span className="muted">system</span>}</td>
                    </tr>
                  );
                })}
                {!rows.length && <tr><td colSpan={9} className="empty">{loading ? 'Loading…' : 'مفيش حركات للمنتج ده في النطاق المختار'}</td></tr>}
              </tbody>
            </table>
          </div>
        </>
      )}
    </div>
  );
}

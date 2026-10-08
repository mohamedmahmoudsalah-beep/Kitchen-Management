'use client';
import { useEffect, useMemo, useState } from 'react';
import { ListPlus, Plus, Trash2 } from 'lucide-react';
import { createClient } from '@/lib/supabase/client';
import ProductPicker, { type ProductLite } from '@/components/ProductPicker';
import { fmt, toBase, toPieces, type QtyMode } from '@/lib/qty';
import { ymd } from '@/lib/export';
import type { Kitchen, Reason } from '@/lib/types';

export type EditorDocType = 'PURCHASE' | 'WH_TXN' | 'WASTE' | 'ADJUSTMENT' | 'CLOSING' | 'TRANSFER';

type Line = {
  key: number;
  product: ProductLite | null;
  qty: string;
  mode: QtyMode;
  reasonId: string;
  direction: '' | 'INCREASE' | 'DECREASE';
  note: string;
};

const TITLES: Record<EditorDocType, string> = {
  PURCHASE: 'Purchase', WH_TXN: 'Warehouse transaction', WASTE: 'Waste', ADJUSTMENT: 'Stock adjustment',
  CLOSING: 'Closing / stock count', TRANSFER: 'Transfer',
};
const POST_LABEL: Record<EditorDocType, string> = {
  PURCHASE: 'Post', WH_TXN: 'Post', WASTE: 'Post', ADJUSTMENT: 'Post', CLOSING: 'Post count', TRANSFER: 'Send',
};

let seq = 1;
const newLine = (): Line => ({ key: seq++, product: null, qty: '', mode: 'BASE', reasonId: '', direction: '', note: '' });

export default function DocumentEditor({ docType, kitchenId, kitchenName, kitchens, docId, isAdmin, defaultDate, onClose, onChanged }: {
  docType: EditorDocType; kitchenId: string; kitchenName: string; kitchens: Kitchen[]; docId: string | null;
  isAdmin: boolean; defaultDate: string; onClose: () => void; onChanged: (message: string) => void;
}) {
  const supabase = useMemo(() => createClient(), []);
  const [id, setId] = useState<string | null>(docId);
  const [date, setDate] = useState(defaultDate || ymd(new Date()));
  const [note, setNote] = useState('');
  const [counterpart, setCounterpart] = useState('');
  const [lines, setLines] = useState<Line[]>([newLine()]);
  const [reasons, setReasons] = useState<Reason[]>([]);
  const [balances, setBalances] = useState<Record<string, number>>({});
  const [override, setOverride] = useState('');
  const [applyCount, setApplyCount] = useState(true);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [loading, setLoading] = useState(!!docId);

  const needsReason = docType === 'WASTE' || docType === 'ADJUSTMENT';
  const isOut = docType === 'WH_TXN' || docType === 'WASTE' || docType === 'TRANSFER';

  // الأسباب (قايمة مشتركة)
  useEffect(() => {
    if (!needsReason) return;
    supabase.from('reasons').select('id,name,direction,is_active,is_system').eq('is_active', true).order('created_at')
      .then(({ data }) => setReasons((data ?? []) as Reason[]));
  }, [supabase, needsReason]);

  // تحميل Draft موجود
  useEffect(() => {
    if (!docId) return;
    (async () => {
      const [{ data: d }, { data: ls }] = await Promise.all([
        supabase.from('documents').select('doc_date,note,counterpart_kitchen_id').eq('id', docId).maybeSingle(),
        supabase.from('document_lines')
          .select('line_no,qty_input,input_mode,qty_base,reason_id,note,products(id,syt_code,generic_code,name,uom_factor,cost_per_uom)')
          .eq('document_id', docId).order('line_no'),
      ]);
      if (d) { setDate(d.doc_date); setNote(d.note ?? ''); setCounterpart(d.counterpart_kitchen_id ?? ''); }
      setLines(((ls ?? []) as unknown as {
        qty_input: number; input_mode: QtyMode; qty_base: number; reason_id: string | null; note: string | null; products: ProductLite;
      }[]).map((l) => ({
        key: seq++, product: l.products, qty: String(Number(l.qty_input)), mode: l.input_mode, reasonId: l.reason_id ?? '',
        direction: docType === 'ADJUSTMENT' ? (Number(l.qty_base) < 0 ? 'DECREASE' : 'INCREASE') : '', note: l.note ?? '',
      })));
      setLoading(false);
    })();
  }, [supabase, docId, docType]);

  // الرصيد المتاح لكل منتج (الوحدة الأساسية)
  const pids = useMemo(() => Array.from(new Set(lines.map((l) => l.product?.id).filter((x): x is string => !!x))), [lines]);
  const pidKey = pids.join(',');
  useEffect(() => {
    if (!pids.length) { setBalances({}); return; }
    supabase.from('stock_balances').select('product_id,qty_base').eq('kitchen_id', kitchenId).eq('location', 'WAREHOUSE').in('product_id', pids)
      .then(({ data }) => {
        const m: Record<string, number> = {};
        pids.forEach((p) => { m[p] = 0; });
        (data ?? []).forEach((r) => { m[r.product_id] = Number(r.qty_base); });
        setBalances(m);
      });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [supabase, kitchenId, pidKey]);

  const reasonOf = (l: Line) => reasons.find((r) => r.id === l.reasonId);
  const effDirection = (l: Line): '' | 'INCREASE' | 'DECREASE' => {
    if (docType !== 'ADJUSTMENT') return '';
    const r = reasonOf(l);
    if (!r) return '';
    return r.direction === 'ANY' ? l.direction : r.direction;
  };
  const baseOf = (l: Line): number | null => {
    const n = Number(l.qty);
    if (!l.product || l.qty.trim() === '' || !Number.isFinite(n)) return null;
    return toBase(n, l.mode, Number(l.product.uom_factor));
  };

  // الخروج المطلوب لكل منتج (لمقارنته بالمتاح)
  const outByProduct = useMemo(() => {
    const m: Record<string, number> = {};
    lines.forEach((l) => {
      const b = baseOf(l);
      if (b === null || !l.product) return;
      const out = isOut ? b : docType === 'ADJUSTMENT' && effDirection(l) === 'DECREASE' ? b : 0;
      if (out > 0) m[l.product.id] = (m[l.product.id] ?? 0) + out;
    });
    return m;
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [lines, reasons]);

  const problems: string[] = [];
  lines.forEach((l, i) => {
    const n = i + 1;
    if (!l.product) { problems.push(`سطر ${n}: اختار المنتج`); return; }
    const q = Number(l.qty);
    if (l.qty.trim() === '' || !Number.isFinite(q)) problems.push(`سطر ${n}: اكتب الكمية`);
    else if (docType === 'CLOSING' ? q < 0 : q <= 0) problems.push(`سطر ${n}: الكمية ${docType === 'CLOSING' ? 'لازم تكون صفر أو أكبر' : 'لازم تكون أكبر من صفر'}`);
    if (needsReason && !l.reasonId) problems.push(`سطر ${n}: اختار السبب`);
    if (docType === 'ADJUSTMENT' && l.reasonId && !effDirection(l)) problems.push(`سطر ${n}: حدد زيادة ولا نقص`);
  });
  if (docType === 'TRANSFER' && !counterpart) problems.push('اختار المطبخ المستلم');
  Object.entries(outByProduct).forEach(([pid, need]) => {
    const avail = balances[pid] ?? 0;
    if (need > avail + 1e-9) {
      const p = lines.find((l) => l.product?.id === pid)?.product;
      problems.push(`${p?.syt_code}: المطلوب ${fmt(need)} أكبر من المتاح ${fmt(avail)}`);
    }
  });

  const setLine = (key: number, patch: Partial<Line>) => setLines((ls) => ls.map((l) => (l.key === key ? { ...l, ...patch } : l)));

  async function loadStockList() {
    const rows: { product_id: string; products: ProductLite }[] = [];
    for (let from = 0; ; from += 1000) {
      const { data, error } = await supabase.from('stock_balances')
        .select('product_id,products(id,syt_code,generic_code,name,uom_factor,cost_per_uom)')
        .eq('kitchen_id', kitchenId).eq('location', 'WAREHOUSE').gt('qty_base', 0).order('product_id').range(from, from + 999);
      if (error) { setErr(error.message); return; }
      rows.push(...((data ?? []) as unknown as typeof rows));
      if (!data || data.length < 1000) break;
    }
    const have = new Set(lines.map((l) => l.product?.id));
    const add = rows.filter((r) => !have.has(r.product_id)).map((r) => ({ ...newLine(), product: r.products }));
    setLines((ls) => [...ls.filter((l) => l.product || l.qty), ...add].sort((a, b) => (a.product?.syt_code ?? '').localeCompare(b.product?.syt_code ?? '')));
  }

  async function save(): Promise<string | null> {
    const payload = lines.map((l) => ({
      product_id: l.product?.id, qty: l.qty.trim(), mode: l.mode,
      reason_id: l.reasonId || undefined, direction: docType === 'ADJUSTMENT' ? effDirection(l) || undefined : undefined,
      note: l.note || undefined,
    }));
    const { data, error } = await supabase.rpc('save_document', {
      p_id: id, p_type: docType, p_kitchen: kitchenId, p_date: date, p_note: note || null, p_lines: payload,
      p_counterpart: docType === 'TRANSFER' ? counterpart || null : null,
    });
    if (error) { setErr(error.message); return null; }
    setId(data as string);
    return data as string;
  }

  async function onSave() {
    setBusy(true); setErr(null);
    const saved = await save();
    setBusy(false);
    if (saved) onChanged('اتحفظ الـ Draft');
  }

  async function onPost() {
    setBusy(true); setErr(null);
    const saved = await save();
    if (saved) {
      const { error } = await supabase.rpc('post_document', { p_doc: saved, p_override_reason: override.trim() || null, p_apply_count: applyCount });
      if (error) setErr(`${error.message} (الـ Draft اتحفظ)`);
      else { setBusy(false); onChanged(docType === 'TRANSFER' ? 'التحويل اتبعت (In Transit)' : 'اتعمل Post'); return; }
    }
    setBusy(false);
  }

  async function onDelete() {
    if (!id || !window.confirm('حذف الـ Draft؟')) return;
    setBusy(true);
    const { error } = await supabase.rpc('delete_draft', { p_doc: id });
    setBusy(false);
    if (error) setErr(error.message); else onChanged('اتحذف الـ Draft');
  }

  const others = kitchens.filter((k) => k.id !== kitchenId);
  const reasonOptions = reasons.filter((r) => (docType === 'WASTE' ? r.direction !== 'INCREASE' : true));

  return (
    <div className="panel" style={{ borderColor: 'var(--magenta)' }}>
      <div className="page-head" style={{ marginBottom: 10 }}>
        <h2 style={{ margin: 0 }}>{id ? 'Edit' : 'New'} {TITLES[docType].toLowerCase()} · {kitchenName}</h2>
        <span className="spacer" />
        <button className="btn secondary small" onClick={onClose}>Close</button>
      </div>

      {loading ? <div className="muted">Loading…</div> : (
        <>
          <div className="form-row">
            <label className="field"><span>{docType === 'CLOSING' ? 'Count date' : 'Date'}</span>
              <input type="date" value={date} onChange={(e) => setDate(e.target.value)} /></label>
            {docType === 'TRANSFER' && (
              <label className="field"><span>To (receiving kitchen)</span>
                <select value={counterpart} onChange={(e) => setCounterpart(e.target.value)}>
                  <option value="">— select —</option>
                  {others.map((k) => <option key={k.id} value={k.id}>{k.name}</option>)}
                </select>
              </label>
            )}
            <label className="field" style={{ flex: 1, minWidth: 220 }}><span>Note</span>
              <input type="text" value={note} onChange={(e) => setNote(e.target.value)} dir="auto" /></label>
            {isAdmin && (
              <label className="field" style={{ minWidth: 220 }}><span>Override reason (closed period — Admin)</span>
                <input type="text" value={override} onChange={(e) => setOverride(e.target.value)} dir="auto" /></label>
            )}
          </div>

          <div className="table-wrap" style={{ marginTop: 12 }}>
            <table className="grid">
              <thead><tr>
                <th>#</th><th>Product</th><th className="num">{docType === 'CLOSING' ? 'Book balance' : 'Available'}</th>
                <th>Quantity</th><th>In</th><th>= Base / Syt pcs</th>
                {needsReason && <th>Reason</th>}{docType === 'ADJUSTMENT' && <th>Effect</th>}
                <th>Note</th><th />
              </tr></thead>
              <tbody>
                {lines.map((l, i) => {
                  const b = baseOf(l);
                  const f = Number(l.product?.uom_factor ?? 1);
                  const avail = l.product ? balances[l.product.id] ?? 0 : null;
                  const over = l.product && outByProduct[l.product.id] > (balances[l.product.id] ?? 0) + 1e-9;
                  const r = reasonOf(l);
                  return (
                    <tr key={l.key}>
                      <td>{i + 1}</td>
                      <td><ProductPicker value={l.product} onChange={(p) => setLine(l.key, { product: p })} /></td>
                      <td className="num" style={{ color: over ? 'var(--err)' : undefined }}>
                        {avail === null ? '—' : <>{fmt(avail)}{f !== 1 && <div className="muted" style={{ fontSize: '.85em' }}>({fmt(toPieces(avail, f))} pcs)</div>}</>}
                      </td>
                      <td><input type="text" inputMode="decimal" value={l.qty} onChange={(e) => setLine(l.key, { qty: e.target.value })} style={{ width: 90 }} /></td>
                      <td>
                        <select value={l.mode} onChange={(e) => setLine(l.key, { mode: e.target.value as QtyMode })}>
                          <option value="BASE">Base (kg)</option>
                          <option value="PIECE">Syt pcs</option>
                        </select>
                      </td>
                      <td className="muted">
                        {b === null ? '—' : <>{fmt(b)}{f > 0 && <> · {fmt(toPieces(b, f))} pcs</>}</>}
                      </td>
                      {needsReason && (
                        <td>
                          <select value={l.reasonId} onChange={(e) => setLine(l.key, { reasonId: e.target.value, direction: '' })} dir="auto">
                            <option value="">— reason —</option>
                            {reasonOptions.map((x) => <option key={x.id} value={x.id}>{x.name}</option>)}
                          </select>
                        </td>
                      )}
                      {docType === 'ADJUSTMENT' && (
                        <td>
                          {!r ? <span className="muted">—</span> : r.direction === 'ANY' ? (
                            <select value={l.direction} onChange={(e) => setLine(l.key, { direction: e.target.value as Line['direction'] })}>
                              <option value="">— + / − —</option>
                              <option value="INCREASE">+ Increase</option>
                              <option value="DECREASE">− Decrease</option>
                            </select>
                          ) : <span className={`badge ${r.direction === 'INCREASE' ? 'ok' : 'err'}`}>{r.direction === 'INCREASE' ? '+ Increase' : '− Decrease'}</span>}
                        </td>
                      )}
                      <td><input type="text" value={l.note} onChange={(e) => setLine(l.key, { note: e.target.value })} dir="auto" style={{ width: 140 }} /></td>
                      <td><button className="icon-btn" style={{ color: 'var(--muted)' }} onClick={() => setLines((ls) => (ls.length > 1 ? ls.filter((x) => x.key !== l.key) : [newLine()]))} title="Remove line"><Trash2 size={14} /></button></td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>

          {docType === 'CLOSING' && (
            <label className="checks" style={{ marginTop: 10 }} dir="auto">
              <span><input type="checkbox" checked={applyCount} onChange={(e) => setApplyCount(e.target.checked)} />{' '}
                Apply count variances to stock (يسجّل الفروق عن رصيد الدفتر كتسوية Count Correction، والجرد ده يبقى Opening الفترة اللي بعده)</span>
            </label>
          )}
          <div className="form-row" style={{ marginTop: 10 }}>
            <button className="btn secondary small" onClick={() => setLines((ls) => [...ls, newLine()])}><Plus size={13} /> Add line</button>
            {docType === 'CLOSING' && <button className="btn secondary small" onClick={loadStockList}><ListPlus size={13} /> Load stock list</button>}
            <span className="muted">{lines.length} lines</span>
          </div>

          {problems.length > 0 && (
            <div className="alert warn" style={{ marginTop: 12 }} dir="auto">
              {problems.slice(0, 6).map((p, i) => <div key={i}>{p}</div>)}
              {problems.length > 6 && <div>… و {problems.length - 6} ملاحظة تانية</div>}
            </div>
          )}
          {err && <div className="alert err" style={{ marginTop: 12 }} dir="auto">{err}</div>}

          <div className="form-row" style={{ marginTop: 14 }}>
            <button className="btn secondary" disabled={busy} onClick={onSave}>Save draft</button>
            <button className="btn" disabled={busy || problems.length > 0} onClick={onPost}>{POST_LABEL[docType]}</button>
            {id && <button className="btn danger" disabled={busy} onClick={onDelete}>Delete draft</button>}
          </div>
        </>
      )}
    </div>
  );
}

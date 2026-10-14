'use client';
import { useEffect, useMemo, useState } from 'react';
import { createClient } from '@/lib/supabase/client';
import ProductPicker, { type ProductLite } from '@/components/ProductPicker';
import type { Reason } from '@/lib/types';

export type LineEditRow = {
  line_no: number; product: ProductLite; qty_input: number; input_mode: 'PIECE' | 'BASE'; qty_base: number;
  reason_id: string | null; note: string | null;
};

// تعديل سطر واحد في مستند اتعمله Post (بدل Reverse للمستند كله). السطر الصفري = من غير تأثير على الرصيد.
export default function LineEditForm({ docId, docType, row, onCancel, onSaved }: {
  docId: string; docType: string; row: LineEditRow; onCancel: () => void; onSaved: (text: string) => void;
}) {
  const supabase = useMemo(() => createClient(), []);
  const needsReason = docType === 'WASTE' || docType === 'ADJUSTMENT';
  const closing = docType === 'CLOSING';
  const [product, setProduct] = useState<ProductLite | null>(row.product);
  const [qty, setQty] = useState(String(Number(row.qty_input)));
  const [mode, setMode] = useState<'PIECE' | 'BASE'>(row.input_mode);
  const [reasonId, setReasonId] = useState(row.reason_id ?? '');
  const [dir, setDir] = useState<'INCREASE' | 'DECREASE'>(Number(row.qty_base) < 0 ? 'DECREASE' : 'INCREASE');
  const [note, setNote] = useState(row.note ?? '');
  const [why, setWhy] = useState('');
  const [reasons, setReasons] = useState<Reason[]>([]);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => {
    if (!needsReason) return;
    supabase.from('reasons').select('id,name,direction,is_active,is_system').eq('is_active', true).order('created_at')
      .then(({ data }) => setReasons((data ?? []) as Reason[]));
  }, [supabase, needsReason]);

  const reasonOptions = reasons.filter((r) => (docType === 'WASTE' ? r.direction !== 'INCREASE' : true));
  const n = Number(qty);
  const qtyOk = qty.trim() !== '' && Number.isFinite(n) && n >= 0;
  const problems: string[] = [];
  if (!product) problems.push('اختار المنتج');
  if (!qtyOk) problems.push('الكمية لازم تكون رقم صفر أو أكبر');
  if (needsReason && !reasonId) problems.push('اختار السبب');
  if (!why.trim()) problems.push('اكتب سبب التعديل');

  async function save() {
    setBusy(true); setErr(null);
    const data: Record<string, string> = { qty: qty.trim(), mode, note };
    if (!closing && product) data.product_id = product.id;
    if (needsReason) data.reason_id = reasonId;
    if (docType === 'ADJUSTMENT') data.direction = dir;
    const { error } = await supabase.rpc('edit_document_line', { p_doc: docId, p_line_no: row.line_no, p_data: data, p_reason: why.trim() });
    setBusy(false);
    if (error) { setErr(error.message); return; }
    onSaved(`اتعدّل السطر ${row.line_no}`);
  }

  return (
    <div className="panel" style={{ margin: '8px 0', borderColor: 'var(--magenta)' }} dir="auto">
      <b>تعديل السطر {row.line_no}</b>
      <span className="muted"> — بيتصلّح السطر ده بس (من غير Reverse للمستند كله)، وبيتسجل مين عدّل وليه.</span>
      <div className="form-row" style={{ marginTop: 8, alignItems: 'flex-end' }}>
        <label className="field" style={{ minWidth: 300 }}><span>Product{closing ? ' (ثابت في الجرد)' : ''}</span>
          <ProductPicker value={product} onChange={setProduct} disabled={closing} /></label>
        <label className="field" style={{ width: 120 }}><span>Qty</span>
          <input type="number" min={0} step="any" value={qty} onChange={(e) => setQty(e.target.value)} /></label>
        <label className="field" style={{ width: 130 }}><span>Entered as</span>
          <select value={mode} onChange={(e) => setMode(e.target.value as 'PIECE' | 'BASE')}>
            <option value="BASE">Base (kg)</option><option value="PIECE">Syt pcs</option></select></label>
        {needsReason && (
          <label className="field" style={{ width: 170 }}><span>Reason</span>
            <select value={reasonId} onChange={(e) => setReasonId(e.target.value)}>
              <option value="">— اختار —</option>
              {reasonOptions.map((r) => <option key={r.id} value={r.id}>{r.name}</option>)}</select></label>
        )}
        {docType === 'ADJUSTMENT' && (
          <label className="field" style={{ width: 120 }}><span>Effect</span>
            <select value={dir} onChange={(e) => setDir(e.target.value as 'INCREASE' | 'DECREASE')}>
              <option value="INCREASE">+ Increase</option><option value="DECREASE">− Decrease</option></select></label>
        )}
        <label className="field" style={{ width: 200 }}><span>Note</span>
          <input type="text" value={note} onChange={(e) => setNote(e.target.value)} dir="auto" /></label>
      </div>
      <div className="form-row" style={{ marginTop: 8, alignItems: 'flex-end' }}>
        <label className="field" style={{ minWidth: 340 }}><span>سبب التعديل (إجباري)</span>
          <input type="text" value={why} onChange={(e) => setWhy(e.target.value)} dir="auto" /></label>
        <button className="btn" disabled={busy || problems.length > 0} onClick={save}>{busy ? 'Saving…' : 'Save line'}</button>
        <button className="btn secondary" disabled={busy} title="يخلي كمية السطر صفر (يفضل في المستند من غير تأثير على الرصيد)" onClick={() => setQty('0')}>Zero this line</button>
        <button className="btn secondary" disabled={busy} onClick={onCancel}>Cancel</button>
      </div>
      {closing && <div className="muted" style={{ marginTop: 6 }}>تعديل كمية الجرد بيعدّل تسوية فرق المنتج ده تلقائيًا (Count Correction)، والرصيد الحالي مبيبقاش سالب.</div>}
      {problems.length > 0 && <div className="muted" style={{ marginTop: 6 }}>{problems.join(' · ')}</div>}
      {err && <div className="alert err" style={{ marginTop: 8 }}>{err}</div>}
    </div>
  );
}

'use client';
import { useMemo, useState } from 'react';
import { createClient } from '@/lib/supabase/client';
import type { Product } from '@/lib/types';

type F = { syt_code: string; generic_code: string; name: string; uom_name: string; category: string; factor: string; cost: string; cost_per_uom: string };

const empty: F = { syt_code: '', generic_code: '', name: '', uom_name: '', category: '', factor: '', cost: '', cost_per_uom: '' };
const fromProduct = (p: Product): F => ({
  syt_code: p.syt_code, generic_code: p.generic_code ?? '', name: p.name, uom_name: p.uom_name ?? '', category: p.category ?? '',
  factor: String(Number(p.uom_factor)), cost: String(Number(p.cost)), cost_per_uom: String(Number(p.cost_per_uom)),
});

export default function ProductForm({ product, onClose, onSaved }: { product: Product | null; onClose: () => void; onSaved: () => void }) {
  const supabase = useMemo(() => createClient(), []);
  const [f, setF] = useState<F>(product ? fromProduct(product) : empty);
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const set = (k: keyof F) => (e: React.ChangeEvent<HTMLInputElement>) => setF({ ...f, [k]: e.target.value });

  async function save() {
    setBusy(true); setErr(null);
    // لو المستخدم غيّر Cost بس أو Cost per UOM بس، التاني بيتحسب في الـ DB
    const data: Record<string, string> = { ...f };
    if (product) {
      if (f.cost === String(Number(product.cost))) delete data.cost;
      if (f.cost_per_uom === String(Number(product.cost_per_uom))) delete data.cost_per_uom;
      if (f.cost !== String(Number(product.cost)) && f.cost_per_uom === String(Number(product.cost_per_uom))) delete data.cost_per_uom;
    }
    const { error } = await supabase.rpc('save_product', { p_id: product?.id ?? null, p_data: data });
    setBusy(false);
    if (error) { setErr(error.message); return; }
    onSaved();
  }

  const factor = Number(f.factor), cost = Number(f.cost), cpu = Number(f.cost_per_uom);
  const mismatch = factor > 0 && cost > 0 && cpu > 0 && Math.abs(cost - factor * cpu) > Math.max(0.01, 0.02 * cost);

  return (
    <div className="panel" style={{ borderColor: 'var(--magenta)' }}>
      <h2>{product ? `Edit ${product.syt_code}` : 'Add product'}</h2>
      <div className="form-row">
        <label className="field"><span>Syt Code *</span><input type="text" value={f.syt_code} onChange={set('syt_code')} /></label>
        <label className="field"><span>Generic Code</span><input type="text" value={f.generic_code} onChange={set('generic_code')} /></label>
        <label className="field" style={{ minWidth: 260 }}><span>Product Name *</span><input type="text" value={f.name} onChange={set('name')} dir="auto" /></label>
        <label className="field"><span>UoM (as in Odoo)</span><input type="text" value={f.uom_name} onChange={set('uom_name')} /></label>
        <label className="field"><span>Product/Financial Category</span><input type="text" value={f.category} onChange={set('category')} dir="auto" /></label>
      </div>
      <div className="form-row" style={{ marginTop: 10 }}>
        <label className="field"><span>Base Qty per Syt (كود السيستم = كام كيلو/وحدة)</span>
          <input type="text" inputMode="decimal" value={f.factor} onChange={set('factor')} placeholder="1" /></label>
        <label className="field"><span>Cost (per Syt code)</span>
          <input type="text" inputMode="decimal" value={f.cost} onChange={set('cost')} /></label>
        <label className="field"><span>Cost Pr UOM (per base unit)</span>
          <input type="text" inputMode="decimal" value={f.cost_per_uom} onChange={set('cost_per_uom')} /></label>
      </div>
      <p className="muted" style={{ margin: '8px 0 0' }} dir="auto">
        لو كتبت Cost بس بيتحسب Cost Pr UOM = Cost ÷ Base Qty، ولو كتبت Cost Pr UOM بس بيتحسب Cost = Cost Pr UOM × Base Qty.
      </p>
      {mismatch && <div className="alert warn" style={{ marginTop: 8 }} dir="auto">Cost مش بيساوي Base Qty × Cost Pr UOM — راجع الأرقام (هيتحفظ برضو وبيتعلّم بتنبيه).</div>}
      {err && <div className="alert err" style={{ marginTop: 8 }} dir="auto">{err}</div>}
      <div className="form-row" style={{ marginTop: 12 }}>
        <button className="btn" disabled={busy || !f.syt_code.trim() || !f.name.trim()} onClick={save}>{busy ? 'Saving…' : 'Save'}</button>
        <button className="btn secondary" onClick={onClose}>Cancel</button>
      </div>
    </div>
  );
}

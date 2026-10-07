'use client';
import { useCallback, useEffect, useMemo, useState } from 'react';
import { AlertTriangle, Download, FileUp, Pencil, Plus, RefreshCw, Search } from 'lucide-react';
import { createClient } from '@/lib/supabase/client';
import { downloadCsv, downloadXlsx, ymd } from '@/lib/export';
import ImportWizard from '@/components/ImportWizard';
import ProductForm from '@/components/ProductForm';
import type { Product } from '@/lib/types';

const PAGE = 50;
const COLS = 'id,generic_code,syt_code,name,category,uom_name,uom_factor,cost,cost_per_uom,cost_mismatch,is_active';
const HEAD = ['Syt Code', 'Generic Code', 'Product Name', 'UoM', 'Product/Financial Category', 'Base Qty per Syt', 'Cost', 'Cost Pr UOM', 'Active'];

const clean = (q: string) => q.replace(/[,()*%]/g, ' ').trim();
const toRow = (p: Product) => [p.syt_code, p.generic_code, p.name, p.uom_name, p.category, Number(p.uom_factor), Number(p.cost), Number(p.cost_per_uom), p.is_active ? 'Yes' : 'No'];
const num = (v: number) => Number(v).toLocaleString(undefined, { maximumFractionDigits: 4 });

type Panel = null | { kind: 'add' } | { kind: 'edit'; product: Product } | { kind: 'import'; mode: 'upsert' | 'update' };

export default function ProductsView({ canManage, isAdmin }: { canManage: boolean; isAdmin: boolean }) {
  const supabase = useMemo(() => createClient(), []);
  const [q, setQ] = useState('');
  const [debounced, setDebounced] = useState('');
  const [page, setPage] = useState(0);
  const [rows, setRows] = useState<Product[]>([]);
  const [count, setCount] = useState(0);
  const [loading, setLoading] = useState(true);
  const [err, setErr] = useState<string | null>(null);
  const [exporting, setExporting] = useState(false);
  const [panel, setPanel] = useState<Panel>(null);
  const [reload, setReload] = useState(0);
  const [note, setNote] = useState<string | null>(null);

  useEffect(() => { const t = setTimeout(() => { setDebounced(clean(q)); setPage(0); }, 250); return () => clearTimeout(t); }, [q]);

  const query = useCallback((from: number, to: number, withCount: boolean) => {
    let qb = supabase.from('products').select(COLS, withCount ? { count: 'exact' } : undefined).order('syt_code').range(from, to);
    if (debounced) qb = qb.or(`name.ilike.%${debounced}%,syt_code.ilike.%${debounced}%,generic_code.ilike.%${debounced}%`);
    return qb;
  }, [supabase, debounced]);

  useEffect(() => {
    let alive = true;
    setLoading(true);
    query(page * PAGE, page * PAGE + PAGE - 1, true).then(({ data, count: c, error }) => {
      if (!alive) return;
      if (error) setErr(error.message); else { setErr(null); setRows((data ?? []) as unknown as Product[]); setCount(c ?? 0); }
      setLoading(false);
    });
    return () => { alive = false; };
  }, [query, page, reload]);

  async function fetchAll(): Promise<Product[]> {
    const all: Product[] = [];
    for (let from = 0; ; from += 1000) {
      const { data, error } = await query(from, from + 999, false);
      if (error) throw error;
      all.push(...((data ?? []) as unknown as Product[]));
      if (!data || data.length < 1000) break;
    }
    return all;
  }

  async function doExport(kind: 'csv' | 'xlsx') {
    setExporting(true);
    try {
      const all = await fetchAll();
      const name = `data-product-${ymd(new Date())}.${kind}`;
      if (kind === 'csv') downloadCsv(name, HEAD, all.map(toRow)); else await downloadXlsx(name, HEAD, all.map(toRow));
    } catch (e) { setErr((e as Error).message); }
    setExporting(false);
  }

  async function adminAction(fn: 'delete_product' | 'set_product_active', p: Product, active?: boolean) {
    if (fn === 'delete_product' && !window.confirm(`حذف ${p.syt_code}؟ (مسموح للمنتجات غير المستخدمة بس)`)) return;
    setErr(null);
    const { error } = fn === 'delete_product'
      ? await supabase.rpc('delete_product', { p_id: p.id })
      : await supabase.rpc('set_product_active', { p_id: p.id, p_active: active });
    if (error) setErr(error.message); else { setNote(null); setReload((n) => n + 1); }
  }

  const pages = Math.max(1, Math.ceil(count / PAGE));
  const done = () => { setPanel(null); setReload((n) => n + 1); };

  return (
    <>
      {panel?.kind === 'add' && <ProductForm product={null} onClose={() => setPanel(null)} onSaved={() => { setNote('اتضاف المنتج'); done(); }} />}
      {panel?.kind === 'edit' && <ProductForm product={panel.product} onClose={() => setPanel(null)} onSaved={() => { setNote('اتحفظ التعديل'); done(); }} />}
      {panel?.kind === 'import' && (
        <div className="panel" style={{ borderColor: 'var(--magenta)' }}>
          <div className="page-head" style={{ marginBottom: 8 }}>
            <h2 style={{ margin: 0 }}>{panel.mode === 'update' ? 'Update products from file' : 'Import products file'}</h2>
            <span className="spacer" />
            <button className="btn secondary small" onClick={() => { setPanel(null); setReload((n) => n + 1); }}>Close</button>
          </div>
          <div style={{ display: 'grid', gap: 16 }}>
            <ImportWizard key={panel.mode} allowed={['products']} isAdmin={isAdmin} fixedModule="products" initialMode={panel.mode} onDone={() => setReload((n) => n + 1)} />
          </div>
        </div>
      )}

      <div className="panel flush">
        <div className="toolbar">
          <div style={{ position: 'relative' }}>
            <Search size={14} style={{ position: 'absolute', left: 8, top: 9, color: 'var(--muted)' }} />
            <input type="search" value={q} onChange={(e) => setQ(e.target.value)} placeholder="Search name or code" style={{ paddingLeft: 28, width: 260 }} />
          </div>
          <span className="muted">{count.toLocaleString()} products</span>
          <span className="spacer" />
          {canManage && (
            <>
              <button className="btn" onClick={() => { setPanel({ kind: 'add' }); setNote(null); }}><Plus size={14} /> Add product</button>
              <button className="btn secondary" onClick={() => { setPanel({ kind: 'import', mode: 'upsert' }); setNote(null); }}><FileUp size={14} /> Import file</button>
              <button className="btn secondary" onClick={() => { setPanel({ kind: 'import', mode: 'update' }); setNote(null); }}><RefreshCw size={14} /> Update from file</button>
            </>
          )}
          <button className="btn secondary" disabled={exporting} onClick={() => doExport('csv')}><Download size={14} /> CSV</button>
          <button className="btn secondary" disabled={exporting} onClick={() => doExport('xlsx')}><Download size={14} /> XLSX</button>
        </div>
        {note && <div className="alert ok" style={{ margin: 12 }} dir="auto">{note}</div>}
        {err && <div className="alert err" style={{ margin: 12 }} dir="auto">{err}</div>}
        <div className="table-wrap">
          <table className="grid">
            <thead><tr>
              <th>Syt Code</th><th>Generic Code</th><th>Product Name</th><th>UoM</th><th>Category</th>
              <th className="num" title="كود السيستم الواحد = كام وحدة أساسية">Base Qty / Syt</th>
              <th className="num">Cost</th><th className="num">Cost Pr UOM</th><th>Status</th>{canManage && <th />}
            </tr></thead>
            <tbody>
              {rows.map((p) => (
                <tr key={p.id}>
                  <td className="mono">{p.syt_code}</td>
                  <td className="mono">{p.generic_code ?? ''}</td>
                  <td dir="auto">{p.name}</td>
                  <td>{p.uom_name ?? ''}</td>
                  <td dir="auto">{p.category ?? ''}</td>
                  <td className="num">{num(p.uom_factor)}</td>
                  <td className="num">
                    {p.cost_mismatch && <span title="Cost مش بيساوي Base Qty × Cost Pr UOM"><AlertTriangle size={13} color="var(--warn)" style={{ marginRight: 4, verticalAlign: '-2px' }} /></span>}
                    {num(p.cost)}
                  </td>
                  <td className="num">{num(p.cost_per_uom)}</td>
                  <td><span className={`badge ${p.is_active ? 'ok' : ''}`}>{p.is_active ? 'Active' : 'Inactive'}</span></td>
                  {canManage && (
                    <td style={{ whiteSpace: 'nowrap' }}>
                      <button className="btn secondary small" onClick={() => { setPanel({ kind: 'edit', product: p }); setNote(null); }}><Pencil size={12} /> Edit</button>
                      {isAdmin && (
                        <>
                          {' '}<button className="btn secondary small" onClick={() => adminAction('set_product_active', p, !p.is_active)}>{p.is_active ? 'Deactivate' : 'Activate'}</button>
                          {' '}<button className="btn danger small" onClick={() => adminAction('delete_product', p)}>Delete</button>
                        </>
                      )}
                    </td>
                  )}
                </tr>
              ))}
              {!rows.length && <tr><td colSpan={canManage ? 10 : 9} className="empty">{loading ? 'Loading…' : 'No products'}</td></tr>}
            </tbody>
          </table>
        </div>
        <div className="pager">
          <button className="btn secondary small" disabled={page === 0} onClick={() => setPage((p) => p - 1)}>Previous</button>
          <span className="muted">Page {page + 1} of {pages}</span>
          <button className="btn secondary small" disabled={page + 1 >= pages} onClick={() => setPage((p) => p + 1)}>Next</button>
        </div>
      </div>
    </>
  );
}

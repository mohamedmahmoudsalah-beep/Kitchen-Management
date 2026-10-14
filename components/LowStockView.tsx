'use client';
import { useCallback, useEffect, useMemo, useState } from 'react';
import { Download, FileSpreadsheet, Search, Upload } from 'lucide-react';
import { createClient } from '@/lib/supabase/client';
import { useScope } from '@/components/ScopeProvider';
import { downloadCsv, downloadXlsx } from '@/lib/export';
import { readTable } from '@/lib/import/parse-file';
import { levelsFromTable, MISSING_LABEL, STATUS_BADGE, STATUS_LABEL, type LevelRow, type StockStatus } from '@/lib/low-stock';
import { fmt } from '@/lib/qty';

type Row = { item_key: string; product_name: string; category: string | null; sizes: number; qty: number; value: number; low_qty: number | null; high_qty: number | null; status: StockStatus };
type Result = { ok: boolean; errors?: { row: number; column: string; reason: string }[]; error_count?: number; count?: number; created?: number; updated?: number; unchanged?: number; removed?: number; committed?: boolean };
const ORDER: StockStatus[] = ['LOW', 'AVG', 'HIGH', 'NOT_SET'];

export default function LowStockView({ canUpload }: { canUpload: boolean }) {
  const supabase = useMemo(() => createClient(), []);
  const { kitchenId, kitchen } = useScope();
  const [rows, setRows] = useState<Row[]>([]);
  const [loading, setLoading] = useState(true);
  const [err, setErr] = useState<string | null>(null);
  const [q, setQ] = useState('');
  const [filter, setFilter] = useState<StockStatus | 'ALL'>('ALL');
  const [open, setOpen] = useState(false);
  const [mode, setMode] = useState<'upsert' | 'replace'>('upsert');
  const [parsed, setParsed] = useState<{ name: string; rows: LevelRow[]; ignored: string[] } | null>(null);
  const [fileErr, setFileErr] = useState<string | null>(null);
  const [res, setRes] = useState<Result | null>(null);
  const [busy, setBusy] = useState(false);
  const [done, setDone] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true); setErr(null);
    const { data, error } = await supabase.rpc('report_low_stock', { p_kitchen: kitchenId });
    if (error) setErr(error.message);
    else setRows((data as Row[]).map((r) => ({ ...r, qty: Number(r.qty), value: Number(r.value), low_qty: r.low_qty === null ? null : Number(r.low_qty), high_qty: r.high_qty === null ? null : Number(r.high_qty) })));
    setLoading(false);
  }, [supabase, kitchenId]);
  useEffect(() => { load(); }, [load]);
  // تغيير المطبخ بيمسح الملف المتحمّل (كل مطبخ له شيته)
  useEffect(() => { setParsed(null); setRes(null); setFileErr(null); setDone(null); }, [kitchenId]);

  const counts = useMemo(() => {
    const c: Record<StockStatus, number> = { LOW: 0, AVG: 0, HIGH: 0, NOT_SET: 0 };
    rows.forEach((r) => { c[r.status]++; });
    return c;
  }, [rows]);
  const needle = q.trim().toLowerCase();
  const shown = rows.filter((r) => (filter === 'ALL' || r.status === filter)
    && (!needle || `${r.item_key} ${r.product_name} ${r.category ?? ''}`.toLowerCase().includes(needle)));

  const head = ['Code', 'Product', 'Category', 'Qty (base)', 'Low Stock', 'High Stock', 'Status', 'Value @ current cost'];
  const exportRows = () => shown.map((r) => [r.item_key, r.product_name, r.category, r.qty, r.low_qty, r.high_qty, STATUS_LABEL[r.status], Math.round(r.value * 100) / 100]);
  const fileBase = `low-stock-${kitchen?.code ?? ''}`;
  const template = () => downloadXlsx(`low-stock-template-${kitchen?.code ?? ''}.xlsx`, ['Code', 'Product', 'Low Stock', 'High Stock'],
    rows.length ? rows.map((r) => [r.item_key, r.product_name, r.low_qty, r.high_qty]) : [['RM0500', 'Example product', 10, 50]]);

  async function pick(file: File | undefined) {
    setParsed(null); setRes(null); setFileErr(null); setDone(null);
    if (!file) return;
    try {
      const f = levelsFromTable(await readTable(file));
      if (f.missing.length) { setFileErr(`أعمدة ناقصة: ${f.missing.map((m) => MISSING_LABEL[m] ?? m).join('، ')} (المطلوب: Code و Low Stock و High Stock)`); return; }
      if (!f.rows.length) { setFileErr('الملف مفيهوش صفوف'); return; }
      setParsed({ name: file.name, rows: f.rows, ignored: f.ignored });
    } catch (e) { setFileErr(e instanceof Error ? e.message : 'مقدرتش أقرا الملف'); }
  }
  async function run(commit: boolean) {
    if (!parsed) return;
    setBusy(true); setErr(null); setDone(null);
    const { data, error } = await supabase.rpc('stock_levels_import', { p_kitchen: kitchenId, p_rows: parsed.rows, p_mode: mode, p_commit: commit });
    setBusy(false);
    if (error) { setErr(error.message); return; }
    const r = data as Result;
    setRes(commit ? null : r);
    if (commit && r.ok) {
      setDone(`اتحفظت حدود ${r.count} صنف لمطبخ ${kitchen?.name}: ${r.created} جديد، ${r.updated} متعدّل، ${r.unchanged} زي ما هو${r.removed ? `، ${r.removed} اتشال` : ''}.`);
      setParsed(null); setRes(null);
      await load();
    }
  }

  return (
    <div style={{ display: 'grid', gap: 12 }}>
      <div className="cards">
        {ORDER.map((s) => (
          <button key={s} type="button" className="card clickable" style={{ textAlign: 'left', font: 'inherit' }} onClick={() => setFilter(filter === s ? 'ALL' : s)}>
            <div className="k"><span className={`badge ${STATUS_BADGE[s]}`}>{STATUS_LABEL[s]}</span></div>
            <div className="v">{counts[s].toLocaleString()}</div><div className="muted">items · {kitchen?.name}</div>
          </button>
        ))}
      </div>

      {canUpload && (
        <div className="panel">
          <div style={{ display: 'flex', gap: 10, alignItems: 'center', flexWrap: 'wrap' }}>
            <b>Stock levels · {kitchen?.name}</b>
            <span className="muted" dir="auto">كل مطبخ بيترفعله شيت لوحده: Code و Low Stock و High Stock (بالوحدة الأساسية).</span>
            <span style={{ flex: 1 }} />
            <button className="btn secondary" onClick={template} title="شيت بالأصناف الحالية (والحدود الحالية لو موجودة) عشان تملاه"><FileSpreadsheet size={14} /> Excel template</button>
            <button className="btn" onClick={() => setOpen((o) => !o)}><Upload size={14} /> {open ? 'Close' : 'Import levels'}</button>
          </div>
          {open && (
            <div style={{ display: 'grid', gap: 10, marginTop: 12 }}>
              <div className="muted" dir="auto">
                الحالة: الرصيد <b>أقل من أو يساوي Low Stock</b> = Low، و<b>أكبر من أو يساوي High Stock</b> = High، وبينهم = Avg. الـ Code ممكن يكون Syt Code أو Generic Code، والحدود بتتطبّق على المنتج كله (كل أحجامه مجموعة).
              </div>
              <div style={{ display: 'flex', gap: 10, alignItems: 'center', flexWrap: 'wrap' }}>
                <select value={mode} onChange={(e) => { setMode(e.target.value as 'upsert' | 'replace'); setRes(null); }}>
                  <option value="upsert">Add &amp; update (الأصناف اللي مش في الملف تفضل زي ما هي)</option>
                  <option value="replace">Replace all (الأصناف اللي مش في الملف حدودها تتشال)</option>
                </select>
                <input type="file" accept=".xlsx,.csv,.txt" onChange={(e) => pick(e.target.files?.[0])} />
              </div>
              {fileErr && <div className="alert err" dir="auto">{fileErr}</div>}
              {parsed && (
                <div style={{ display: 'flex', gap: 10, alignItems: 'center', flexWrap: 'wrap' }}>
                  <span className="muted" dir="auto">{parsed.name} · {parsed.rows.length} صف{parsed.ignored.length ? ` · أعمدة اتجاهلت: ${parsed.ignored.join(', ')}` : ''}</span>
                  <button className="btn secondary" disabled={busy} onClick={() => run(false)}>Validate file</button>
                  {res?.ok && <button className="btn" disabled={busy} onClick={() => run(true)}>Save {res.count} items</button>}
                </div>
              )}
              {res?.ok && (
                <div className="alert ok" dir="auto">
                  الملف سليم: {res.created} صنف جديد، {res.updated} هيتعدّل، {res.unchanged} زي ما هو{res.removed ? `، و${res.removed} هيتشال (Replace all)` : ''}.
                </div>
              )}
              {res && !res.ok && (
                <div>
                  <div className="alert err" dir="auto">فيه {res.error_count} خطأ، ومفيش ولا صف اتحفظ. صلّح الملف وارفعه تاني.</div>
                  <table className="grid" style={{ marginTop: 8 }}>
                    <thead><tr><th>Row</th><th>Column</th><th>Reason</th></tr></thead>
                    <tbody>{res.errors?.map((e, i) => <tr key={i}><td>{e.row}</td><td>{e.column}</td><td dir="auto">{e.reason}</td></tr>)}</tbody>
                  </table>
                  {(res.error_count ?? 0) > (res.errors?.length ?? 0) && <div className="muted">بيظهر أول {res.errors?.length} خطأ بس.</div>}
                </div>
              )}
            </div>
          )}
          {done && <div className="alert ok" style={{ marginTop: 10 }} dir="auto">{done}</div>}
        </div>
      )}

      <div className="panel flush">
        <div className="toolbar">
          <div style={{ position: 'relative' }}>
            <Search size={14} style={{ position: 'absolute', left: 8, top: 9, color: 'var(--muted)' }} />
            <input type="search" value={q} onChange={(e) => setQ(e.target.value)} placeholder="Search code or product" style={{ paddingLeft: 28, width: 230 }} />
          </div>
          <div className="chips">
            <button className={`chip ${filter === 'ALL' ? 'on' : ''}`} onClick={() => setFilter('ALL')}>All ({rows.length})</button>
            {ORDER.map((s) => <button key={s} className={`chip ${filter === s ? 'on' : ''}`} onClick={() => setFilter(filter === s ? 'ALL' : s)}>{STATUS_LABEL[s]} ({counts[s]})</button>)}
          </div>
          <span className="muted" dir="auto">{kitchen?.name} · الرصيد الحالي (لايف) · {shown.length} صنف</span>
          <span className="spacer" />
          <button className="btn secondary" disabled={!shown.length} onClick={() => downloadCsv(`${fileBase}.csv`, head, exportRows())}><Download size={14} /> CSV</button>
          <button className="btn secondary" disabled={!shown.length} onClick={() => downloadXlsx(`${fileBase}.xlsx`, head, exportRows())}><Download size={14} /> XLSX</button>
        </div>
        {err && <div className="alert err" style={{ margin: 12 }} dir="auto">{err}</div>}
        <div className="table-wrap">
          <table className="grid">
            <thead><tr>
              <th>Code</th><th>Product</th><th>Category</th>
              <th className="num">Qty (base)</th><th className="num" title="الرصيد أقل من أو يساوي الرقم ده = Low">Low ≤</th><th className="num" title="الرصيد أكبر من أو يساوي الرقم ده = High">High ≥</th>
              <th>Status</th><th className="num">Value @ current cost</th>
            </tr></thead>
            <tbody>
              {shown.map((r) => (
                <tr key={r.item_key}>
                  <td className="mono">{r.item_key}{r.sizes > 1 && <div className="muted">{r.sizes} sizes</div>}</td>
                  <td dir="auto">{r.product_name}</td><td className="muted" dir="auto">{r.category ?? '—'}</td>
                  <td className="num"><b>{fmt(r.qty)}</b></td>
                  <td className="num">{r.low_qty === null ? '—' : fmt(r.low_qty)}</td><td className="num">{r.high_qty === null ? '—' : fmt(r.high_qty)}</td>
                  <td><span className={`badge ${STATUS_BADGE[r.status]}`}>{STATUS_LABEL[r.status]}</span></td>
                  <td className="num">{fmt(r.value, 2)}</td>
                </tr>
              ))}
              {!shown.length && <tr><td colSpan={8} className="empty">{loading ? 'Loading…' : rows.length ? 'مفيش أصناف بالفلتر ده' : 'مفيش رصيد ولا حدود للمطبخ ده لسه'}</td></tr>}
            </tbody>
          </table>
        </div>
      </div>
    </div>
  );
}

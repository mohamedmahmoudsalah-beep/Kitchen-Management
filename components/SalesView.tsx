'use client';
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { Download, RefreshCw, Trash2, Upload } from 'lucide-react';
import { createClient } from '@/lib/supabase/client';
import { useScope } from '@/components/ScopeProvider';
import { readSalesFile, normKitchen, type ParsedSales } from '@/lib/sales-file';
import { downloadCsv, downloadXlsx } from '@/lib/export';
import { fmt } from '@/lib/qty';
import { invalidateAll } from '@/lib/cache';

type Day = { date: string; products: number; units: number; unmapped_units: number; doc_no: string | null };
type Prod = { pid: string; name: string | null; qty: number; has_bom: boolean; days: number };
type Live = { days: Day[]; products: Prod[] };
type MapRow = { sales_name: string; kitchen_id: string };
type Snap = { id: string; from_date: string; to_date: string; created_at: string };
type SnapSales = { pid: string; name: string | null; qty: number; has_bom: boolean; days: number }[];
type Tab = 'days' | 'products' | 'unmapped' | 'saved';

// المبيعات بتترفع شهر بشهر. كل يوم/مطبخ بيعمل مستند SALES بيخصم الـ RM من الـ BOM (والرصيد يقدر يبقى سالب).
// عند قفل الشهر: بيتحفظ ملخص المبيعات والاستهلاك وبتتمسح داتا المبيعات الخام.
export default function SalesView({ canWrite, canManage, isAdmin }: { canWrite: boolean; canManage: boolean; isAdmin: boolean }) {
  const supabase = useMemo(() => createClient(), []);
  const { kitchenId, kitchen, kitchens, from, to } = useScope();
  const [live, setLive] = useState<Live>({ days: [], products: [] });
  const [loading, setLoading] = useState(true);
  const [tab, setTab] = useState<Tab>('days');
  const [msg, setMsg] = useState<{ kind: 'ok' | 'err' | 'warn'; text: string } | null>(null);
  const [maps, setMaps] = useState<MapRow[]>([]);
  const [snaps, setSnaps] = useState<Snap[]>([]);
  const [snapSel, setSnapSel] = useState<{ snap: Snap; sales: SnapSales } | null>(null);
  const [q, setQ] = useState('');

  const load = useCallback(async () => {
    setLoading(true);
    const { data, error } = await supabase.rpc('sales_live', { p_kitchen: kitchenId, p_from: from, p_to: to });
    if (error) { setMsg({ kind: 'err', text: error.message }); setLive({ days: [], products: [] }); }
    else {
      const d = data as Live;
      setLive({ days: d.days.map((x) => ({ ...x, units: Number(x.units), unmapped_units: Number(x.unmapped_units) })), products: d.products.map((p) => ({ ...p, qty: Number(p.qty) })) });
    }
    setLoading(false);
  }, [supabase, kitchenId, from, to]);
  const loadMaps = useCallback(async () => {
    const { data } = await supabase.from('sales_kitchen_map').select('sales_name,kitchen_id').order('sales_name');
    setMaps((data ?? []) as MapRow[]);
  }, [supabase]);
  const loadSnaps = useCallback(async () => {
    const { data } = await supabase.from('period_snapshots').select('id,from_date,to_date,created_at').eq('kitchen_id', kitchenId).order('from_date', { ascending: false });
    setSnaps((data ?? []) as Snap[]); setSnapSel(null);
  }, [supabase, kitchenId]);
  useEffect(() => { load(); }, [load]);
  useEffect(() => { loadMaps(); }, [loadMaps]);
  useEffect(() => { loadSnaps(); }, [loadSnaps]);

  const totals = useMemo(() => ({
    units: live.days.reduce((s, d) => s + d.units, 0), unm: live.days.reduce((s, d) => s + d.unmapped_units, 0),
  }), [live.days]);
  const unmapped = live.products.filter((p) => !p.has_bom);
  const needle = q.trim().toLowerCase();
  const prodShown = live.products.filter((p) => !needle || `${p.pid} ${p.name ?? ''}`.toLowerCase().includes(needle));

  async function delDay(d: string) {
    if (!window.confirm(`مسح مبيعات ${d} لمطبخ ${kitchen?.name}؟ هيرجّع الـ RM اللي اتخصم.`)) return;
    const { error } = await supabase.rpc('sales_delete_day', { p_kitchen: kitchenId, p_date: d, p_reason: null });
    if (error) setMsg({ kind: 'err', text: error.message }); else { setMsg({ kind: 'ok', text: `اتمسحت مبيعات ${d} واتعمل Reverse للخصم` }); load(); }
  }

  async function openSnap(s: Snap) {
    const { data } = await supabase.from('period_snapshots').select('sales').eq('id', s.id).maybeSingle();
    setSnapSel({ snap: s, sales: ((data?.sales ?? []) as SnapSales).map((x) => ({ ...x, qty: Number(x.qty) })) });
  }

  return (
    <>
      {msg && <div className={`alert ${msg.kind}`} dir="auto" style={{ marginBottom: 12 }}>{msg.text}</div>}
      {canWrite && <ImportPanel supabase={supabase} maps={maps} canManage={canManage} isAdmin={isAdmin}
        onMapsChanged={loadMaps} onDone={(t, kind) => { invalidateAll(); setMsg({ kind, text: t }); load(); }} />}

      <div className="panel flush">
        <div className="toolbar">
          {([['days', 'Days'], ['products', 'Products'], ['unmapped', `No BOM (${unmapped.length})`], ['saved', `Saved months (${snaps.length})`]] as [Tab, string][]).map(([k, l]) => (
            <button key={k} className={`btn small ${tab === k ? '' : 'secondary'}`} onClick={() => setTab(k)}>{l}</button>
          ))}
          <span className="muted" dir="auto">{kitchen?.name} · {from} → {to} · {fmt(totals.units)} وحدة{totals.unm > 0 && <> · <b style={{ color: 'var(--err)' }}>{fmt(totals.unm)}</b> بدون BOM</>}</span>
          <span className="spacer" />
          <button className="btn secondary" onClick={() => { invalidateAll(); load(); loadSnaps(); }}><RefreshCw size={14} /> Refresh</button>
        </div>

        {tab === 'days' && (
          <div className="table-wrap"><table className="grid">
            <thead><tr><th>Date</th><th className="num">Products</th><th className="num">Units sold</th><th className="num">Units without BOM</th><th>Deduction doc</th><th /></tr></thead>
            <tbody>
              {live.days.map((d) => (
                <tr key={d.date}>
                  <td>{d.date}</td><td className="num">{d.products}</td><td className="num">{fmt(d.units)}</td>
                  <td className="num" style={d.unmapped_units > 0 ? { color: 'var(--err)' } : undefined}>{fmt(d.unmapped_units)}</td>
                  <td className="mono">{d.doc_no}</td>
                  <td>{canWrite && <button className="icon-btn" title="Delete this day (reverses the deduction)" onClick={() => delDay(d.date)}><Trash2 size={14} /></button>}</td>
                </tr>
              ))}
              {!live.days.length && <tr><td colSpan={6} className="empty">{loading ? 'Loading…' : 'مفيش مبيعات مرفوعة في الفترة دي (الشهور المقفولة في Saved months)'}</td></tr>}
            </tbody>
          </table></div>
        )}

        {(tab === 'products' || tab === 'unmapped') && (
          <>
            <div className="toolbar" style={{ borderTop: '1px solid var(--line)' }}>
              <input type="search" value={q} onChange={(e) => setQ(e.target.value)} placeholder="Search product" style={{ width: 240 }} />
              <span className="spacer" />
              <button className="btn secondary" disabled={!prodShown.length} onClick={() => {
                const rows = (tab === 'unmapped' ? unmapped.filter((p) => prodShown.includes(p)) : prodShown).map((p) => [p.pid, p.name, p.qty, p.days, p.has_bom ? 'Yes' : 'No']);
                downloadCsv(`sales-${tab}-${kitchen?.code ?? ''}-${from}_${to}.csv`, ['Product ID', 'Product', 'Qty', 'Days', 'Has BOM'], rows);
              }}><Download size={14} /> CSV</button>
              <button className="btn secondary" disabled={!prodShown.length} onClick={() => {
                const rows = (tab === 'unmapped' ? unmapped.filter((p) => prodShown.includes(p)) : prodShown).map((p) => [p.pid, p.name, p.qty, p.days, p.has_bom ? 'Yes' : 'No']);
                downloadXlsx(`sales-${tab}-${kitchen?.code ?? ''}-${from}_${to}.xlsx`, ['Product ID', 'Product', 'Qty', 'Days', 'Has BOM'], rows);
              }}><Download size={14} /> XLSX</button>
            </div>
            {tab === 'unmapped' && <div className="muted" style={{ margin: '0 14px 8px' }} dir="auto">منتجات اتباعت ومالهاش BOM — مبتخصمش RM. ضيفها في الـ BOM وارفع المبيعات تاني (Replace) لو عايز تتخصم.</div>}
            <div className="table-wrap"><table className="grid">
              <thead><tr><th>Product ID</th><th>Product</th><th className="num">Qty sold</th><th className="num">Days</th><th>BOM</th></tr></thead>
              <tbody>
                {(tab === 'unmapped' ? prodShown.filter((p) => !p.has_bom) : prodShown).map((p) => (
                  <tr key={p.pid}><td className="mono">{p.pid}</td><td dir="auto">{p.name}</td><td className="num">{fmt(p.qty)}</td><td className="num">{p.days}</td>
                    <td><span className={`badge ${p.has_bom ? 'ok' : 'err'}`}>{p.has_bom ? 'Yes' : 'No BOM'}</span></td></tr>
                ))}
                {!prodShown.length && <tr><td colSpan={5} className="empty">{loading ? 'Loading…' : 'No data'}</td></tr>}
              </tbody>
            </table></div>
          </>
        )}

        {tab === 'saved' && (
          <div style={{ padding: 14 }} dir="auto">
            <div className="muted" style={{ marginBottom: 8 }}>ملخصات الشهور اللي اتقفلت (المبيعات الخام اتمسحت بعد القفل، والملخص والاستهلاك اتحفظوا).</div>
            <div className="form-row">
              {snaps.map((s) => (
                <button key={s.id} className={`btn small ${snapSel?.snap.id === s.id ? '' : 'secondary'}`} onClick={() => openSnap(s)}>{s.from_date.slice(0, 7)}</button>
              ))}
              {!snaps.length && <span className="muted">مفيش شهور متقفلة لسه لمطبخ {kitchen?.name}</span>}
            </div>
            {snapSel && (
              <>
                <div className="form-row" style={{ marginTop: 10 }}>
                  <b>{snapSel.snap.from_date} → {snapSel.snap.to_date}</b>
                  <span className="muted">اتحفظ {new Date(snapSel.snap.created_at).toLocaleString()}</span>
                  <span className="spacer" />
                  <button className="btn secondary small" onClick={() => downloadXlsx(`sales-summary-${kitchen?.code ?? ''}-${snapSel.snap.from_date.slice(0, 7)}.xlsx`, ['Product ID', 'Product', 'Qty', 'Days', 'Has BOM'],
                    snapSel.sales.map((p) => [p.pid, p.name, p.qty, p.days, p.has_bom ? 'Yes' : 'No']))}><Download size={13} /> XLSX</button>
                </div>
                <div className="table-wrap" style={{ marginTop: 8 }}><table className="grid">
                  <thead><tr><th>Product ID</th><th>Product</th><th className="num">Qty sold</th><th className="num">Days</th><th>BOM</th></tr></thead>
                  <tbody>{snapSel.sales.map((p) => <tr key={p.pid}><td className="mono">{p.pid}</td><td dir="auto">{p.name}</td><td className="num">{fmt(p.qty)}</td><td className="num">{p.days}</td>
                    <td><span className={`badge ${p.has_bom ? 'ok' : 'err'}`}>{p.has_bom ? 'Yes' : 'No BOM'}</span></td></tr>)}</tbody>
                </table></div>
              </>
            )}
          </div>
        )}
      </div>

      {canManage && <MapPanel supabase={supabase} kitchens={kitchens} maps={maps} onChanged={loadMaps} />}
    </>
  );
}

type Sb = ReturnType<typeof createClient>;

function ImportPanel({ supabase, maps, canManage, isAdmin, onMapsChanged, onDone }: {
  supabase: Sb; maps: MapRow[]; canManage: boolean; isAdmin: boolean; onMapsChanged: () => void; onDone: (text: string, kind: 'ok' | 'warn') => void;
}) {
  const { kitchens } = useScope();
  const [parsed, setParsed] = useState<{ name: string; data: ParsedSales } | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [replace, setReplace] = useState(false);
  const [override, setOverride] = useState('');
  const [busy, setBusy] = useState<string | null>(null);
  const [fails, setFails] = useState<string[]>([]);
  const input = useRef<HTMLInputElement>(null);
  const [pick, setPick] = useState<Record<string, string>>({});

  const mapOf = useMemo(() => new Map(maps.map((m) => [m.sales_name, m.kitchen_id])), [maps]);
  const kName = (id: string) => kitchens.find((k) => k.id === id)?.name;
  const resolved = (key: string) => mapOf.get(key) ?? null;

  async function onFile(f: File | null) {
    setParsed(null); setErr(null); setFails([]);
    if (!f) return;
    setBusy('بقرا الملف…');
    try { setParsed({ name: f.name, data: await readSalesFile(f) }); } catch (e) { setErr(e instanceof Error ? e.message : String(e)); }
    setBusy(null);
  }

  async function saveMap(key: string) {
    const kid = pick[key]; if (!kid) return;
    const { error } = await supabase.rpc('sales_map_save', { p_name: key, p_kitchen: kid });
    if (error) setErr(error.message); else onMapsChanged();
  }

  const d = parsed?.data;
  const blockers: string[] = [];
  const importable = d ? d.groups.filter((g) => { const kid = resolved(g.kitchenKey); return !!kid && kitchens.some((k) => k.id === kid); }) : [];
  if (d) {
    for (const k of d.kitchens) {
      const kid = resolved(k.key);
      if (!kid) blockers.push(`المطبخ "${k.name}" مش مربوط بمطبخ في النظام`);
      else if (!kitchens.some((x) => x.id === kid)) blockers.push(`المطبخ "${k.name}" مربوط بمطبخ مش في نطاقك — هيتتجاهل`);
    }
  }
  const hardBlock = !d || !importable.length || d.kitchens.some((k) => !resolved(k.key));

  async function run() {
    if (!d) return;
    setErr(null); setFails([]);
    let done = 0, rm = 0, unm = 0; const missing = new Set<string>(); const bad: string[] = [];
    for (const g of importable) {
      setBusy(`برفع ${g.date} · ${g.kitchenName} (${done + 1}/${importable.length})…`);
      const { data, error } = await supabase.rpc('sales_import_day', {
        p_kitchen: resolved(g.kitchenKey), p_date: g.date,
        p_rows: g.rows.map((r) => ({ pid: r.pid, name: r.name, qty: String(r.qty) })), p_replace: replace, p_override: override.trim() || null,
      });
      if (error) { bad.push(`${g.date} · ${g.kitchenName}: ${error.message}`); break; }
      const r = data as { rm_lines: number; unmapped_units: number; missing_rm: string[] };
      done++; rm += r.rm_lines; unm += Number(r.unmapped_units); r.missing_rm.forEach((c) => missing.add(c));
    }
    setBusy(null);
    if (bad.length) { setFails(bad); }
    const parts = [`اترفع ${done} يوم/مطبخ · ${rm} سطر RM اتخصم`];
    if (unm > 0) parts.push(`${fmt(unm)} وحدة بدون BOM (شوف تبويب No BOM)`);
    if (missing.size) parts.push(`خامات مالهاش منتج Active في Data Product: ${[...missing].slice(0, 10).join(', ')}`);
    if (bad.length) parts.push('وقف عند أول خطأ — اللي قبله اترفع. لو عايز تعيد الرفع فعّل Replace');
    onDone(parts.join(' · '), bad.length || unm > 0 || missing.size ? 'warn' : 'ok');
    if (!bad.length) { setParsed(null); if (input.current) input.current.value = ''; }
  }

  return (
    <div className="panel">
      <div className="page-head" style={{ marginBottom: 8 }}><h2 style={{ margin: 0 }}>Import sales</h2></div>
      <div className="form-row">
        <input ref={input} type="file" accept=".csv,.txt,.tsv,.xlsx" disabled={!!busy} onChange={(e) => onFile(e.target.files?.[0] ?? null)} />
        {busy && <span className="muted">{busy}</span>}
      </div>
      <div className="muted" style={{ marginTop: 6 }} dir="auto">
        ارفع المبيعات شهر بشهر (Delivered At · Breadfast Kitchen Name · Product ID · Order Product Quantity). الـ Modifiers بتتتجاهل، والتاريخ بصيغة شهر/يوم/سنة.
        كل يوم بيتخصم منه الـ RM على حسب الـ BOM، والرصيد يقدر يبقى سالب.
      </div>
      {err && <div className="alert err" style={{ marginTop: 10 }} dir="auto">{err}</div>}
      {d && (
        <div style={{ marginTop: 10 }} dir="auto">
          <div className="alert ok">
            <b>{parsed?.name}</b>: {d.rows} صف منتج · {d.modifiers} Modifier اتتجاهل · {d.groups.length} يوم/مطبخ · {d.dates?.min} → {d.dates?.max}
            {d.bad.length > 0 && <div style={{ color: 'var(--err)' }}>{d.bad.length} صف غلط اتتجاهل (أول واحد: سطر {d.bad[0].row} — {d.bad[0].reason})</div>}
          </div>
          {d.months.length > 1 && <div className="alert warn" style={{ marginTop: 8 }}>الملف فيه {d.months.length} شهور ({d.months.join(', ')}). الأفضل ترفع شهر في كل مرة.</div>}
          <div className="table-wrap" style={{ marginTop: 8 }}><table className="grid">
            <thead><tr><th>Kitchen in file</th><th className="num">Days</th><th className="num">Units</th><th>Maps to</th></tr></thead>
            <tbody>
              {d.kitchens.map((k) => {
                const kid = resolved(k.key);
                return (
                  <tr key={k.key}>
                    <td>{k.name}</td><td className="num">{k.days}</td><td className="num">{fmt(k.units)}</td>
                    <td>{kid ? <span className="badge ok">{kName(kid) ?? 'مطبخ خارج نطاقك'}</span> : canManage ? (
                      <span className="form-row" style={{ margin: 0 }}>
                        <select value={pick[k.key] ?? ''} onChange={(e) => setPick({ ...pick, [k.key]: e.target.value })}>
                          <option value="">— choose kitchen —</option>{kitchens.map((x) => <option key={x.id} value={x.id}>{x.name}</option>)}
                        </select>
                        <button className="btn small" disabled={!pick[k.key]} onClick={() => saveMap(k.key)}>Save mapping</button>
                      </span>
                    ) : <span className="badge err">مش مربوط — اطلب من الـ Admin/Manager</span>}</td>
                  </tr>
                );
              })}
            </tbody>
          </table></div>
          {blockers.map((b, i) => <div key={i} className="muted">• {b}</div>)}
          <div className="form-row" style={{ marginTop: 10 }}>
            <label className="checks"><span><input type="checkbox" checked={replace} onChange={(e) => setReplace(e.target.checked)} /> Replace days that were already imported (يعمل Reverse للخصم القديم ويحط الجديد)</span></label>
            {isAdmin && <label className="field" style={{ minWidth: 240 }}><span>Override reason (closed period — Admin)</span><input type="text" value={override} onChange={(e) => setOverride(e.target.value)} dir="auto" /></label>}
          </div>
          <div className="form-row" style={{ marginTop: 10 }}>
            <button className="btn" disabled={hardBlock || !!busy} onClick={run}><Upload size={14} /> Import {importable.length} day(s) & deduct RM</button>
            {hardBlock && <span className="muted">اربط كل مطابخ الملف الأول</span>}
          </div>
          {fails.map((f, i) => <div key={i} className="alert err" style={{ marginTop: 8 }}>{f}</div>)}
        </div>
      )}
    </div>
  );
}

function MapPanel({ supabase, kitchens, maps, onChanged }: { supabase: Sb; kitchens: { id: string; name: string }[]; maps: MapRow[]; onChanged: () => void }) {
  const [name, setName] = useState(''); const [kid, setKid] = useState(''); const [err, setErr] = useState<string | null>(null);
  async function add() {
    const { error } = await supabase.rpc('sales_map_save', { p_name: normKitchen(name), p_kitchen: kid });
    if (error) setErr(error.message); else { setErr(null); setName(''); setKid(''); onChanged(); }
  }
  async function del(n: string) {
    const { error } = await supabase.rpc('sales_map_delete', { p_name: n });
    if (error) setErr(error.message); else onChanged();
  }
  return (
    <details className="panel" style={{ padding: '10px 14px' }}>
      <summary style={{ cursor: 'pointer', fontWeight: 600 }}>Kitchen name mapping ({maps.length})</summary>
      <div className="muted" style={{ margin: '8px 0' }} dir="auto">ربط اسم المطبخ في ملف المبيعات بالمطبخ في النظام. بيتظبط مرة واحدة.</div>
      {err && <div className="alert err" dir="auto">{err}</div>}
      <div className="form-row">
        <input type="text" value={name} onChange={(e) => setName(e.target.value)} placeholder="Name in sales file, e.g. New Cairo FP #7 Kitchen" style={{ width: 320 }} />
        <select value={kid} onChange={(e) => setKid(e.target.value)}><option value="">— kitchen —</option>{kitchens.map((k) => <option key={k.id} value={k.id}>{k.name}</option>)}</select>
        <button className="btn small" disabled={!name.trim() || !kid} onClick={add}>Add / update</button>
      </div>
      <table className="grid" style={{ marginTop: 8 }}>
        <thead><tr><th>Name in sales file</th><th>Kitchen</th><th /></tr></thead>
        <tbody>
          {maps.map((m) => (
            <tr key={m.sales_name}><td>{m.sales_name}</td><td>{kitchens.find((k) => k.id === m.kitchen_id)?.name ?? m.kitchen_id}</td>
              <td><button className="icon-btn" onClick={() => del(m.sales_name)} title="Remove"><Trash2 size={14} /></button></td></tr>
          ))}
        </tbody>
      </table>
    </details>
  );
}

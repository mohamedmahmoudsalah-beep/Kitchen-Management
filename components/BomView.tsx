'use client';
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { BookOpen, Download, Search, Upload } from 'lucide-react';
import { createClient } from '@/lib/supabase/client';
import { readBomFile, type ParsedBom } from '@/lib/bom-file';
import { downloadCsv } from '@/lib/export';
import { fmt } from '@/lib/qty';

type Meta = { updated_at: string; updated_by_email: string | null; file_name: string | null; products: number; items: number; source_rows: number } | null;
type Check = { rows: number; used_rows: number; skipped_non_positive: number; products: number; items: number; ok: boolean; missing: { code: string; products: number; rows: number }[] };
type Fp = { finished_id: string; finished_name: string | null; items: number };
type Detail = { rm_code: string; rm_name: string | null; qty: number; unit: string | null; category: string | null };
const CHUNK = 5000;
const newBatch = () => (typeof crypto !== 'undefined' && 'randomUUID' in crypto ? crypto.randomUUID() : '00000000-0000-4000-8000-' + String(Date.now()).padStart(12, '0'));

// BOM: وصفة المنتجات التامة بالـ RM (Generic Code). الرفع بيستبدل القديم بالكامل، ومبيتم إلا لما كل أكواد الـ RM تكون في Data Product.
export default function BomView({ canManage }: { canManage: boolean }) {
  const supabase = useMemo(() => createClient(), []);
  const [meta, setMeta] = useState<Meta>(null);
  const [parsed, setParsed] = useState<{ name: string; bom: ParsedBom } | null>(null);
  const [batch, setBatch] = useState<string | null>(null);
  const [check, setCheck] = useState<Check | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [msg, setMsg] = useState<{ kind: 'ok' | 'err' | 'warn'; text: string } | null>(null);
  const file = useRef<HTMLInputElement>(null);

  const [q, setQ] = useState('');
  const [fps, setFps] = useState<Fp[]>([]);
  const [sel, setSel] = useState<Fp | null>(null);
  const [detail, setDetail] = useState<Detail[]>([]);

  const loadMeta = useCallback(async () => {
    const { data } = await supabase.from('bom_meta').select('updated_at,updated_by_email,file_name,products,items,source_rows').maybeSingle();
    setMeta((data as Meta) ?? null);
  }, [supabase]);
  useEffect(() => { loadMeta(); }, [loadMeta]);

  useEffect(() => {
    const t = setTimeout(async () => {
      const { data } = await supabase.rpc('fp_search', { p_q: q || null });
      setFps((data ?? []) as Fp[]);
    }, 200);
    return () => clearTimeout(t);
  }, [supabase, q, meta?.updated_at]);

  useEffect(() => {
    if (!sel) { setDetail([]); return; }
    supabase.rpc('bom_detail', { p_fid: sel.finished_id }).then(({ data }) => setDetail(((data ?? []) as Detail[]).map((d) => ({ ...d, qty: Number(d.qty) }))));
  }, [supabase, sel]);

  async function onFile(f: File | null) {
    setParsed(null); setCheck(null); setBatch(null); setMsg(null);
    if (!f) return;
    setBusy('بقرا الملف…');
    try { setParsed({ name: f.name, bom: await readBomFile(f) }); }
    catch (e) { setMsg({ kind: 'err', text: e instanceof Error ? e.message : String(e) }); }
    setBusy(null);
  }

  async function validate() {
    if (!parsed) return;
    setMsg(null); setCheck(null);
    const id = newBatch();
    try {
      const rows = parsed.bom.rows;
      for (let i = 0; i < rows.length; i += CHUNK) {
        setBusy(`برفع الصفوف ${Math.min(i + CHUNK, rows.length)} / ${rows.length}…`);
        const { error } = await supabase.rpc('bom_stage', { p_batch: id, p_rows: rows.slice(i, i + CHUNK), p_first: i === 0 });
        if (error) throw new Error(error.message);
      }
      setBusy('بفحص الأكواد…');
      const { data, error } = await supabase.rpc('bom_validate', { p_batch: id });
      if (error) throw new Error(error.message);
      setBatch(id); setCheck(data as Check);
    } catch (e) { setMsg({ kind: 'err', text: e instanceof Error ? e.message : String(e) }); }
    setBusy(null);
  }

  async function commit() {
    if (!batch || !parsed) return;
    if (!window.confirm('الـ BOM الحالي هيتشال ويتحط الجديد بدله. المبيعات اللي اتخصمت قبل كده مش هتتأثر. تكمل؟')) return;
    setBusy('بحفظ الـ BOM…'); setMsg(null);
    const { data, error } = await supabase.rpc('bom_commit', { p_batch: batch, p_file_name: parsed.name });
    setBusy(null);
    if (error) { setMsg({ kind: 'err', text: error.message }); return; }
    const r = data as { products: number; items: number };
    setMsg({ kind: 'ok', text: `اتحفظ الـ BOM: ${r.products} منتج · ${r.items} سطر RM/PK` });
    setParsed(null); setCheck(null); setBatch(null); if (file.current) file.current.value = '';
    setSel(null); loadMeta();
  }

  return (
    <>
      <div className="panel">
        <div className="page-head" style={{ marginBottom: 8 }}>
          <h2 style={{ margin: 0 }}><BookOpen size={16} style={{ verticalAlign: -3 }} /> Bill of materials (finished products → RM)</h2>
        </div>
        {meta ? (
          <div dir="auto">آخر رفع: <b>{new Date(meta.updated_at).toLocaleString()}</b> · {meta.updated_by_email ?? ''} · <span className="mono">{meta.file_name ?? ''}</span>
            <div className="muted">{meta.products} منتج تام · {meta.items} سطر (RM/PK) · من {meta.source_rows} صف في الملف</div></div>
        ) : <div className="alert warn" dir="auto">مفيش BOM متسجل لسه. ارفع ملف الـ BOM (.xlsx).</div>}
        {msg && <div className={`alert ${msg.kind}`} style={{ marginTop: 10 }} dir="auto">{msg.text}</div>}

        {canManage ? (
          <div style={{ marginTop: 12 }}>
            <div className="form-row">
              <input ref={file} type="file" accept=".xlsx" disabled={!!busy} onChange={(e) => onFile(e.target.files?.[0] ?? null)} />
              {busy && <span className="muted">{busy}</span>}
            </div>
            <div className="muted" style={{ marginTop: 6 }} dir="auto">
              الأعمدة المطلوبة: Product ID · RM Code · Recipe Include  Waste (باقي الأعمدة اختيارية). الكمية للوحدة الواحدة من المنتج التام (كيلو للخامات، قطعة للتغليف).
              نفس الـ RM في أكتر من Semi بيتجمّع. الرفع بيستبدل الـ BOM كله، ومبيترفعش لو فيه كود RM مش موجود في Data Product (كمنتج Active) — الـ Generic Code هو اللي بيتطابق.
            </div>
            {parsed && (
              <div className="alert ok" style={{ marginTop: 10 }} dir="auto">
                <b>{parsed.name}</b>: {parsed.bom.sourceRows} صف · {parsed.bom.products} منتج · {parsed.bom.rmCodes} كود RM
                {parsed.bom.nonPositive > 0 && <> · {parsed.bom.nonPositive} صف كميته صفر/سالبة (هيتتجاهل)</>}
                <div className="form-row" style={{ marginTop: 8 }}>
                  <button className="btn" disabled={!!busy} onClick={validate}><Upload size={14} /> Validate against Data Product</button>
                </div>
              </div>
            )}
            {check && check.ok && (
              <div className="alert ok" style={{ marginTop: 10 }} dir="auto">
                كل أكواد الـ RM موجودة في Data Product ✓ — جاهز: {check.products} منتج · {check.items} سطر.
                <div className="form-row" style={{ marginTop: 8 }}>
                  <button className="btn" disabled={!!busy} onClick={commit}>Replace BOM</button>
                </div>
              </div>
            )}
            {check && !check.ok && (
              <div className="alert err" style={{ marginTop: 10 }} dir="auto">
                <div><b>{check.missing.length}</b> كود RM في الـ BOM مش موجود في Data Product كمنتج Active — الرفع متوقف. ضيف المنتجات الناقصة في Data Product الأول (أو صحّح الأكواد في الملف) وجرّب تاني.</div>
                <div className="table-wrap" style={{ marginTop: 8, maxHeight: 260, overflow: 'auto' }}>
                  <table className="grid" style={{ background: '#fff' }}>
                    <thead><tr><th>RM Code</th><th className="num">Products using it</th><th className="num">Rows</th></tr></thead>
                    <tbody>{check.missing.map((m) => <tr key={m.code}><td className="mono">{m.code}</td><td className="num">{m.products}</td><td className="num">{m.rows}</td></tr>)}</tbody>
                  </table>
                </div>
                <div className="form-row" style={{ marginTop: 8 }}>
                  <button className="btn secondary small" onClick={() => downloadCsv('bom-missing-rm-codes.csv', ['RM Code', 'Products using it', 'Rows'], check.missing.map((m) => [m.code, m.products, m.rows]))}><Download size={13} /> Missing codes CSV</button>
                </div>
              </div>
            )}
          </div>
        ) : <div className="muted" style={{ marginTop: 10 }} dir="auto">رفع الـ BOM للـ Admin أو الـ Manager بس.</div>}
      </div>

      <div className="panel">
        <div className="toolbar" style={{ padding: 0, marginBottom: 8 }}>
          <div style={{ position: 'relative' }}>
            <Search size={14} style={{ position: 'absolute', left: 8, top: 9, color: 'var(--muted)' }} />
            <input type="search" value={q} onChange={(e) => setQ(e.target.value)} placeholder="Search finished product (name or ID)" style={{ paddingLeft: 28, width: 300 }} />
          </div>
          <span className="muted">{fps.length === 30 ? 'أول 30 نتيجة' : `${fps.length} منتج`}</span>
        </div>
        <div style={{ display: 'grid', gridTemplateColumns: 'minmax(240px, 1fr) 2fr', gap: 14 }}>
          <div style={{ maxHeight: 420, overflow: 'auto', border: '1px solid var(--line)', borderRadius: 8 }}>
            {fps.map((f) => (
              <div key={f.finished_id} onClick={() => setSel(f)} style={{ padding: '8px 12px', cursor: 'pointer', borderBottom: '1px solid #f0f1f6', background: sel?.finished_id === f.finished_id ? 'var(--magenta-soft)' : '#fff' }}>
                <div className="mono">{f.finished_id}</div><div dir="auto">{f.finished_name}</div><div className="muted" style={{ fontSize: '.8rem' }}>{f.items} items</div>
              </div>
            ))}
            {!fps.length && <div className="empty">{meta ? 'مفيش نتيجة' : 'ارفع BOM الأول'}</div>}
          </div>
          <div className="table-wrap">
            {sel ? (
              <table className="grid">
                <thead><tr><th>RM Code</th><th>Name (Data Product)</th><th>Cat</th><th className="num">Qty per unit</th><th>Unit</th></tr></thead>
                <tbody>{detail.map((d) => <tr key={d.rm_code}><td className="mono">{d.rm_code}</td><td dir="auto">{d.rm_name ?? '—'}</td><td>{d.category}</td><td className="num">{fmt(d.qty, 6)}</td><td>{d.unit}</td></tr>)}</tbody>
              </table>
            ) : <div className="empty">اختار منتج تام عشان تشوف الـ RM بتاعته</div>}
          </div>
        </div>
      </div>
    </>
  );
}

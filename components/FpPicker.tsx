'use client';
import { useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react';
import { createPortal } from 'react-dom';
import { X } from 'lucide-react';
import { createClient } from '@/lib/supabase/client';

export type FpLite = { id: string; name: string };
type Row = { finished_id: string; finished_name: string | null; items: number };
type Pos = { left: number; top: number; width: number; maxHeight: number; above: boolean };

// اختيار منتج تام (من الـ BOM) بالاسم أو الـ Product ID — للـ Waste.
export default function FpPicker({ value, onChange, disabled }: { value: FpLite | null; onChange: (p: FpLite | null) => void; disabled?: boolean }) {
  const supabase = useMemo(() => createClient(), []);
  const [q, setQ] = useState('');
  const [open, setOpen] = useState(false);
  const [results, setResults] = useState<Row[]>([]);
  const [loading, setLoading] = useState(false);
  const [active, setActive] = useState(0);
  const [pos, setPos] = useState<Pos | null>(null);
  const box = useRef<HTMLDivElement>(null);
  const list = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!open) return;
    setLoading(true);
    const t = setTimeout(async () => {
      const { data } = await supabase.rpc('fp_search', { p_q: q.trim() || null });
      setResults((data ?? []) as Row[]); setActive(0); setLoading(false);
    }, 180);
    return () => clearTimeout(t);
  }, [q, open, supabase]);

  useLayoutEffect(() => {
    if (!open) return;
    const place = () => {
      const el = box.current; if (!el) return;
      const r = el.getBoundingClientRect();
      const below = window.innerHeight - r.bottom - 12;
      const above = below < 220 && r.top > below;
      const width = Math.min(Math.max(r.width, 380), window.innerWidth - 16);
      const left = Math.max(8, Math.min(r.left, window.innerWidth - width - 8));
      setPos({ left, width, above, top: above ? r.top - 4 : r.bottom + 4, maxHeight: Math.max(160, Math.min(380, (above ? r.top : below) - 8)) });
    };
    place();
    window.addEventListener('scroll', place, true); window.addEventListener('resize', place);
    return () => { window.removeEventListener('scroll', place, true); window.removeEventListener('resize', place); };
  }, [open, results.length]);

  useEffect(() => {
    const h = (e: MouseEvent) => { const t = e.target as Node; if (box.current?.contains(t) || list.current?.contains(t)) return; setOpen(false); };
    document.addEventListener('mousedown', h);
    return () => document.removeEventListener('mousedown', h);
  }, []);

  const pick = (r: Row) => { onChange({ id: r.finished_id, name: r.finished_name ?? r.finished_id }); setOpen(false); setQ(''); };

  if (value) {
    return (
      <div style={{ display: 'flex', alignItems: 'center', gap: 6, minWidth: 220 }}>
        <div style={{ minWidth: 0 }}>
          <div className="mono">{value.id} <span className="badge">Finished</span></div>
          <div dir="auto" style={{ overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap', maxWidth: 260 }}>{value.name}</div>
        </div>
        {!disabled && <button className="icon-btn" style={{ color: 'var(--muted)' }} onClick={() => onChange(null)} title="Change product"><X size={14} /></button>}
      </div>
    );
  }
  return (
    <div ref={box} style={{ position: 'relative', minWidth: 220 }}>
      <input type="text" value={q} placeholder="Finished product (name or ID)…" disabled={disabled} autoComplete="off"
        onFocus={() => setOpen(true)} onChange={(e) => { setQ(e.target.value); setOpen(true); }}
        onKeyDown={(e) => {
          if (e.key === 'ArrowDown') { e.preventDefault(); setOpen(true); setActive((i) => Math.min(i + 1, results.length - 1)); }
          else if (e.key === 'ArrowUp') { e.preventDefault(); setActive((i) => Math.max(i - 1, 0)); }
          else if (e.key === 'Enter' && open && results[active]) { e.preventDefault(); pick(results[active]); }
          else if (e.key === 'Escape') setOpen(false);
        }} style={{ width: '100%' }} />
      {open && pos && createPortal(
        <div ref={list} style={{
          position: 'fixed', zIndex: 1000, left: pos.left, width: pos.width, top: pos.above ? undefined : pos.top,
          bottom: pos.above ? window.innerHeight - pos.top : undefined, maxHeight: pos.maxHeight, overflowY: 'auto',
          background: '#fff', border: '1px solid var(--magenta)', borderRadius: 8, boxShadow: '0 12px 32px rgba(15,21,54,.28)',
        }}>
          <div className="muted" style={{ padding: '6px 12px', fontSize: '.8rem', background: '#fafbfd', borderBottom: '1px solid var(--line)', position: 'sticky', top: 0 }}>
            {loading ? 'Searching…' : `${results.length} نتيجة`} · ↑↓ و Enter للاختيار
          </div>
          {results.map((r, i) => (
            <div key={r.finished_id} onMouseEnter={() => setActive(i)} onMouseDown={(e) => { e.preventDefault(); pick(r); }}
              style={{ padding: '8px 12px', cursor: 'pointer', borderBottom: '1px solid #f0f1f6', background: i === active ? 'var(--magenta-soft)' : '#fff' }}>
              <div style={{ display: 'flex', gap: 8, alignItems: 'baseline' }}><b className="mono">{r.finished_id}</b><span className="muted" style={{ marginLeft: 'auto', fontSize: '.8rem' }}>{r.items} RM</span></div>
              <div dir="auto" style={{ marginTop: 2 }}>{r.finished_name}</div>
            </div>
          ))}
          {!results.length && !loading && <div className="muted" style={{ padding: 14 }}>مفيش منتج تام بالاسم ده — اتأكد إن الـ BOM مرفوع</div>}
        </div>, document.body)}
    </div>
  );
}

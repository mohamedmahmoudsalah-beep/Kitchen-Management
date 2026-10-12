'use client';
import { useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react';
import { createPortal } from 'react-dom';
import { X } from 'lucide-react';
import { createClient } from '@/lib/supabase/client';

export type ProductLite = { id: string; syt_code: string; generic_code: string | null; name: string; uom_factor: number; cost_per_uom: number };
const clean = (q: string) => q.replace(/[,()*%]/g, ' ').trim();
const LIMIT = 20;

type Pos = { left: number; top: number; width: number; maxHeight: number; above: boolean };

// اختيار منتج بالكود أو الاسم. القايمة بتتفتح فوق كل حاجة (Portal) فمبتتقصش جوه الجداول.
export default function ProductPicker({ value, onChange, disabled }: { value: ProductLite | null; onChange: (p: ProductLite | null) => void; disabled?: boolean }) {
  const supabase = useMemo(() => createClient(), []);
  const [q, setQ] = useState('');
  const [open, setOpen] = useState(false);
  const [results, setResults] = useState<ProductLite[]>([]);
  const [loading, setLoading] = useState(false);
  const [active, setActive] = useState(0);
  const [pos, setPos] = useState<Pos | null>(null);
  const box = useRef<HTMLDivElement>(null);
  const list = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!open) return;
    const term = clean(q);
    setLoading(true);
    const t = setTimeout(async () => {
      let qb = supabase.from('products').select('id,syt_code,generic_code,name,uom_factor,cost_per_uom').eq('is_active', true).order('syt_code').limit(LIMIT);
      if (term) qb = qb.or(`name.ilike.%${term}%,syt_code.ilike.%${term}%,generic_code.ilike.%${term}%`);
      const { data } = await qb;
      setResults((data ?? []) as ProductLite[]); setActive(0); setLoading(false);
    }, 180);
    return () => clearTimeout(t);
  }, [q, open, supabase]);

  // مكان القايمة (fixed) + يتحدث مع السكرول/الريسايز
  useLayoutEffect(() => {
    if (!open) return;
    const place = () => {
      const el = box.current; if (!el) return;
      const r = el.getBoundingClientRect();
      const below = window.innerHeight - r.bottom - 12;
      const above = below < 220 && r.top > below;
      const width = Math.min(Math.max(r.width, 460), window.innerWidth - 16);
      const left = Math.max(8, Math.min(r.left, window.innerWidth - width - 8));
      setPos({ left, width, above, top: above ? r.top - 4 : r.bottom + 4, maxHeight: Math.max(160, Math.min(380, (above ? r.top : below) - 8)) });
    };
    place();
    window.addEventListener('scroll', place, true);
    window.addEventListener('resize', place);
    return () => { window.removeEventListener('scroll', place, true); window.removeEventListener('resize', place); };
  }, [open, results.length]);

  useEffect(() => {
    const h = (e: MouseEvent) => {
      const t = e.target as Node;
      if (box.current?.contains(t) || list.current?.contains(t)) return;
      setOpen(false);
    };
    document.addEventListener('mousedown', h);
    return () => document.removeEventListener('mousedown', h);
  }, []);

  useEffect(() => { list.current?.querySelector<HTMLElement>(`[data-i="${active}"]`)?.scrollIntoView({ block: 'nearest' }); }, [active]);

  const pick = (p: ProductLite) => { onChange(p); setOpen(false); setQ(''); };

  if (value) {
    return (
      <div style={{ display: 'flex', alignItems: 'center', gap: 6, minWidth: 220 }}>
        <div style={{ minWidth: 0 }}>
          <div className="mono">{value.syt_code}{value.generic_code ? ` · ${value.generic_code}` : ''}</div>
          <div dir="auto" style={{ overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap', maxWidth: 260 }}>{value.name}</div>
        </div>
        {!disabled && <button className="icon-btn" style={{ color: 'var(--muted)' }} onClick={() => onChange(null)} title="Change product"><X size={14} /></button>}
      </div>
    );
  }
  return (
    <div ref={box} style={{ position: 'relative', minWidth: 220 }}>
      <input type="text" value={q} placeholder="Search code or name…" disabled={disabled} autoComplete="off"
        onFocus={() => setOpen(true)} onChange={(e) => { setQ(e.target.value); setOpen(true); }}
        onKeyDown={(e) => {
          if (e.key === 'ArrowDown') { e.preventDefault(); setOpen(true); setActive((i) => Math.min(i + 1, results.length - 1)); }
          else if (e.key === 'ArrowUp') { e.preventDefault(); setActive((i) => Math.max(i - 1, 0)); }
          else if (e.key === 'Enter' && open && results[active]) { e.preventDefault(); pick(results[active]); }
          else if (e.key === 'Escape') setOpen(false);
        }}
        style={{ width: '100%' }} />
      {open && pos && createPortal(
        <div ref={list} style={{
          position: 'fixed', zIndex: 1000, left: pos.left, width: pos.width, top: pos.above ? undefined : pos.top,
          bottom: pos.above ? window.innerHeight - pos.top : undefined, maxHeight: pos.maxHeight, overflowY: 'auto',
          background: '#fff', border: '1px solid var(--magenta)', borderRadius: 8, boxShadow: '0 12px 32px rgba(15,21,54,.28)',
        }}>
          <div className="muted" style={{ padding: '6px 12px', fontSize: '.8rem', background: '#fafbfd', borderBottom: '1px solid var(--line)', position: 'sticky', top: 0 }}>
            {loading ? 'Searching…' : results.length === LIMIT ? `أول ${LIMIT} نتيجة — اكتب أكتر عشان تضيّق` : `${results.length} نتيجة`} · ↑↓ و Enter للاختيار
          </div>
          {results.map((p, i) => (
            <div key={p.id} data-i={i} onMouseEnter={() => setActive(i)} onMouseDown={(e) => { e.preventDefault(); pick(p); }}
              style={{ padding: '8px 12px', cursor: 'pointer', borderBottom: '1px solid #f0f1f6', background: i === active ? 'var(--magenta-soft)' : '#fff' }}>
              <div style={{ display: 'flex', gap: 8, alignItems: 'baseline', flexWrap: 'wrap' }}>
                <b className="mono">{p.syt_code}</b>
                {p.generic_code && <span className="badge">{p.generic_code}</span>}
                <span className="muted" style={{ marginLeft: 'auto', fontSize: '.8rem' }}>1 Syt = {Number(p.uom_factor)} base</span>
              </div>
              <div dir="auto" style={{ marginTop: 2 }}>{p.name}</div>
            </div>
          ))}
          {!results.length && !loading && <div className="muted" style={{ padding: 14 }}>مفيش منتج بالاسم/الكود ده</div>}
        </div>, document.body)}
    </div>
  );
}

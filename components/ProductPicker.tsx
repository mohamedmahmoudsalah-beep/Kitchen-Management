'use client';
import { useEffect, useMemo, useRef, useState } from 'react';
import { X } from 'lucide-react';
import { createClient } from '@/lib/supabase/client';

export type ProductLite = { id: string; syt_code: string; generic_code: string | null; name: string; uom_factor: number; cost_per_uom: number };
const clean = (q: string) => q.replace(/[,()*%]/g, ' ').trim();

export default function ProductPicker({ value, onChange, disabled }: { value: ProductLite | null; onChange: (p: ProductLite | null) => void; disabled?: boolean }) {
  const supabase = useMemo(() => createClient(), []);
  const [q, setQ] = useState('');
  const [open, setOpen] = useState(false);
  const [results, setResults] = useState<ProductLite[]>([]);
  const box = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!open) return;
    const term = clean(q);
    const t = setTimeout(async () => {
      let qb = supabase.from('products').select('id,syt_code,generic_code,name,uom_factor,cost_per_uom').eq('is_active', true).order('syt_code').limit(8);
      if (term) qb = qb.or(`name.ilike.%${term}%,syt_code.ilike.%${term}%,generic_code.ilike.%${term}%`);
      const { data } = await qb;
      setResults((data ?? []) as ProductLite[]);
    }, 180);
    return () => clearTimeout(t);
  }, [q, open, supabase]);

  useEffect(() => {
    const h = (e: MouseEvent) => { if (box.current && !box.current.contains(e.target as Node)) setOpen(false); };
    document.addEventListener('mousedown', h);
    return () => document.removeEventListener('mousedown', h);
  }, []);

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
      <input type="text" value={q} placeholder="Code or name…" disabled={disabled}
        onFocus={() => setOpen(true)} onChange={(e) => { setQ(e.target.value); setOpen(true); }} style={{ width: '100%' }} />
      {open && (
        <div style={{ position: 'absolute', zIndex: 30, left: 0, right: 0, top: '100%', background: '#fff', border: '1px solid var(--line)', borderRadius: 6, boxShadow: '0 6px 20px rgba(15,21,54,.12)', maxHeight: 260, overflowY: 'auto', minWidth: 300 }}>
          {results.map((p) => (
            <div key={p.id} style={{ padding: '6px 10px', cursor: 'pointer', borderBottom: '1px solid #f0f1f6' }}
              onMouseDown={(e) => { e.preventDefault(); onChange(p); setOpen(false); setQ(''); }}>
              <span className="mono">{p.syt_code}</span>{p.generic_code && <span className="muted"> · {p.generic_code}</span>}
              <div dir="auto">{p.name}</div>
            </div>
          ))}
          {!results.length && <div className="muted" style={{ padding: 10 }}>No matches</div>}
        </div>
      )}
    </div>
  );
}

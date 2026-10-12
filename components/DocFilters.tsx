'use client';
import { useEffect, useState } from 'react';
import { Search, X } from 'lucide-react';

// بحث (Doc No / ملاحظة / كود أو اسم منتج) + فلتر الحالة. البحث بيتأخر 350ms عشان مايضربش الداتا بيز مع كل حرف.
export default function DocFilters({ q, status, statuses, onQ, onStatus }: {
  q: string; status: string; statuses: { value: string; label: string }[]; onQ: (v: string) => void; onStatus: (v: string) => void;
}) {
  const [text, setText] = useState(q);
  useEffect(() => { setText(q); }, [q]);
  useEffect(() => {
    if (text === q) return;
    const t = setTimeout(() => onQ(text), 350);
    return () => clearTimeout(t);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [text]);
  return (
    <div className="toolbar" style={{ background: '#fafbfd' }}>
      <div style={{ position: 'relative', flex: '1 1 260px', maxWidth: 420 }}>
        <Search size={14} style={{ position: 'absolute', left: 9, top: 9, color: 'var(--muted)' }} />
        <input type="search" value={text} placeholder="Search Doc No, product code / name, note…" dir="auto"
          onChange={(e) => setText(e.target.value)} style={{ width: '100%', paddingLeft: 28 }} aria-label="Search documents" />
      </div>
      <select value={status} onChange={(e) => onStatus(e.target.value)} aria-label="Status filter">
        <option value="">All statuses</option>
        {statuses.map((s) => <option key={s.value} value={s.value}>{s.label}</option>)}
      </select>
      {(q || status) && <button className="btn secondary small" onClick={() => { setText(''); onQ(''); onStatus(''); }}><X size={12} /> Clear</button>}
    </div>
  );
}

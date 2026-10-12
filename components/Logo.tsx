'use client';
import { useEffect, useRef, useState } from 'react';

// لوجو Breadfast: حط الملف في public/breadfast-logo.png (أو بدّل LOGO_SRC). لو الملف مش موجود بيظهر حرف K مؤقتًا.
export const LOGO_SRC = '/breadfast-logo.png';

export default function Logo({ size = 32, boxed = false, label }: { size?: number; boxed?: boolean; label?: string }) {
  const ref = useRef<HTMLImageElement>(null);
  const [ok, setOk] = useState(true);
  useEffect(() => { const i = ref.current; if (i && i.complete && i.naturalWidth === 0) setOk(false); }, []);
  const wrap: React.CSSProperties = boxed
    ? { background: '#fff', borderRadius: Math.round(size / 4), padding: Math.round(size / 8), display: 'grid', placeItems: 'center', flex: 'none', width: size, height: size }
    : { display: 'inline-grid', placeItems: 'center', flex: 'none', width: size, height: size };
  if (!ok) {
    return <span className="logo" style={{ width: size, height: size, borderRadius: Math.round(size / 4), background: 'var(--magenta)', color: '#fff', display: 'grid', placeItems: 'center', fontWeight: 700, flex: 'none' }} aria-label={label ?? 'Breadfast'}>K</span>;
  }
  return (
    <span style={wrap}>
      {/* eslint-disable-next-line @next/next/no-img-element */}
      <img ref={ref} src={LOGO_SRC} alt={label ?? 'Breadfast'} onError={() => setOk(false)} style={{ width: '100%', height: '100%', objectFit: 'contain', borderRadius: Math.round(size / 5) }} />
    </span>
  );
}

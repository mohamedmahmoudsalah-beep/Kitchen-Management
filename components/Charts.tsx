'use client';
import { useState } from 'react';
import { compact, linePath, nearestIndex, niceTicks } from '@/lib/chart';

export type Series = { name: string; color: string; values: number[] };

const W = 640, H = 250, L = 52, R = 14, T = 14, B = 28;
const shortDay = (d: string) => d.slice(5);   // MM-DD

// رسم خطوط بالأيام (SVG). hover بيطلّع قيمة كل خط في اليوم
export function LineChart({ labels, series, area = false }: { labels: string[]; series: Series[]; area?: boolean }) {
  const [hover, setHover] = useState<number | null>(null);
  const n = labels.length;
  const max = Math.max(0, ...series.flatMap((s) => s.values));
  const ticks = niceTicks(max);
  const top = ticks[ticks.length - 1] || 1;
  const pw = W - L - R, ph = H - T - B;
  const x = (i: number) => L + (n <= 1 ? pw / 2 : (i / (n - 1)) * pw);
  const y = (v: number) => T + ph - (v / top) * ph;
  const xs = labels.map((_, i) => x(i));
  const step = Math.max(1, Math.ceil(n / 7));

  if (!n) return <div className="muted" style={{ padding: 24 }}>No data</div>;
  return (
    <div className="chart">
      <svg viewBox={`0 0 ${W} ${H}`} role="img" aria-label={series.map((s) => s.name).join(', ')}
        onMouseLeave={() => setHover(null)}
        onMouseMove={(e) => {
          const r = e.currentTarget.getBoundingClientRect();
          setHover(nearestIndex(((e.clientX - r.left) / r.width) * W, L, pw, n));
        }}>
        {ticks.map((t) => (
          <g key={t}>
            <line x1={L} x2={W - R} y1={y(t)} y2={y(t)} stroke="var(--line)" strokeWidth={1} />
            <text x={L - 6} y={y(t) + 4} textAnchor="end" fontSize={11} fill="var(--muted)">{compact(t)}</text>
          </g>
        ))}
        {labels.map((d, i) => (i % step === 0 || i === n - 1) && (
          <text key={d} x={x(i)} y={H - 8} textAnchor="middle" fontSize={11} fill="var(--muted)">{shortDay(d)}</text>
        ))}
        {series.map((s) => (
          <g key={s.name}>
            {area && n > 1 && <path d={`${linePath(xs, s.values.map(y))}L${x(n - 1)},${y(0)}L${x(0)},${y(0)}Z`} fill={s.color} opacity={0.1} />}
            <path d={linePath(xs, s.values.map(y))} fill="none" stroke={s.color} strokeWidth={2} strokeLinejoin="round" />
            {n <= 45 && s.values.map((v, i) => <circle key={i} cx={x(i)} cy={y(v)} r={2.2} fill={s.color} />)}
          </g>
        ))}
        {hover !== null && (
          <g pointerEvents="none">
            <line x1={x(hover)} x2={x(hover)} y1={T} y2={T + ph} stroke="var(--muted)" strokeDasharray="3 3" />
            {series.map((s) => <circle key={s.name} cx={x(hover)} cy={y(s.values[hover])} r={4} fill="#fff" stroke={s.color} strokeWidth={2} />)}
          </g>
        )}
      </svg>
      {hover !== null && (
        <div className="chart-tip" style={{ left: `${(x(hover) / W) * 100}%` }}>
          <b>{labels[hover]}</b>
          {series.map((s) => <div key={s.name}><i style={{ background: s.color }} />{s.name}: {Math.round(s.values[hover]).toLocaleString('en-US')}</div>)}
        </div>
      )}
      {series.length > 1 && (
        <div className="chart-legend">{series.map((s) => <span key={s.name}><i style={{ background: s.color }} />{s.name}</span>)}</div>
      )}
    </div>
  );
}

// أعمدة أفقية (قيمة لكل بند)
export function BarList({ items, color = 'var(--magenta)' }: { items: { label: string; value: number }[]; color?: string }) {
  const max = Math.max(1, ...items.map((i) => i.value));
  if (!items.length) return <div className="muted" style={{ padding: 16 }}>No data</div>;
  return (
    <div className="barlist">
      {items.map((i) => (
        <div key={i.label} className="bar-row" title={`${i.label}: ${Math.round(i.value).toLocaleString('en-US')}`}>
          <span className="bar-label" dir="auto">{i.label}</span>
          <span className="bar-track"><span className="bar-fill" style={{ width: `${(i.value / max) * 100}%`, background: color }} /></span>
          <span className="bar-val">{compact(i.value)}</span>
        </div>
      ))}
    </div>
  );
}

import { fmt, toPieces } from '@/lib/qty';

// بيعرض الكميتين مع بعض: الوحدة الأساسية + عدد أكواد السيستم (لو الـ factor مش 1)
export default function Qty({ base, factor, className }: { base: number | string | null | undefined; factor: number | string; className?: string }) {
  const b = Number(base ?? 0);
  const f = Number(factor);
  return (
    <span className={className}>
      {fmt(b)}
      {f > 0 && f !== 1 && <span className="muted" style={{ marginLeft: 6, fontSize: '.85em' }}>({fmt(toPieces(b, f))} pcs)</span>}
    </span>
  );
}

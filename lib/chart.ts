// دوال مساعدة للرسومات البيانية (SVG بسيط من غير مكتبات)
export function compact(n: number): string {
  const a = Math.abs(n);
  if (a >= 1e9) return `${+(n / 1e9).toFixed(1)}B`;
  if (a >= 1e6) return `${+(n / 1e6).toFixed(1)}M`;
  if (a >= 1e3) return `${+(n / 1e3).toFixed(1)}K`;
  return String(+n.toFixed(a >= 100 ? 0 : 2));
}

// ticks "حلوة" (1/2/5 × 10^n) من الصفر لحد أكبر قيمة
export function niceTicks(max: number, count = 4): number[] {
  if (!Number.isFinite(max) || max <= 0) return [0, 1];
  const raw = max / count;
  const mag = Math.pow(10, Math.floor(Math.log10(raw)));
  const step = [1, 2, 2.5, 5, 10].map((m) => m * mag).find((s) => s >= raw) ?? 10 * mag;
  const out: number[] = [];
  for (let v = 0; v < max + step * 0.999; v += step) out.push(+v.toFixed(10));
  return out;
}

// مسار SVG لخط: النقاط الفاضية (null) بتقطع الخط
export function linePath(xs: number[], ys: (number | null)[]): string {
  let d = ''; let pen = false;
  ys.forEach((y, i) => {
    if (y === null) { pen = false; return; }
    d += `${pen ? 'L' : 'M'}${xs[i].toFixed(1)},${y.toFixed(1)}`; pen = true;
  });
  return d;
}

// أقرب index لمكان الماوس
export function nearestIndex(x: number, left: number, width: number, n: number): number {
  if (n <= 1) return 0;
  const t = Math.min(1, Math.max(0, (x - left) / width));
  return Math.round(t * (n - 1));
}

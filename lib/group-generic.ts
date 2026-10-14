// تجميع صفوف التقارير (Warehouse Stock / Consumption) على مستوى الـ Generic Code:
// كذا Syt Code (أحجام) لنفس الـ Generic = منتج واحد في التقرير. الكميات بالوحدة الأساسية (كيلو) فبتتجمّع مباشرة.
export type GRow = {
  product_id: string; syt_code: string; generic_code: string | null; product_name: string; category: string | null;
  uom_factor: number; cost_per_uom: number;
  [k: string]: unknown;
};
export type Grouped<T extends GRow> = T & { value: number; members: string[]; search: string; grouped: boolean };

const num = (v: unknown) => Number(v ?? 0) || 0;
const r4 = (v: number) => Math.round(v * 10000) / 10000;

// qtyKeys = الأعمدة الكمية اللي هتتجمّع، valueKey = العمود اللي القيمة بتتحسب عليه، preferred = آخر Syt اتشترى لكل Generic
export function groupByGeneric<T extends GRow>(
  rows: T[], qtyKeys: string[], valueKey: string, preferred: Record<string, string> = {}, enabled = true,
): Grouped<T>[] {
  const single = (r: T): Grouped<T> => ({
    ...r, value: num(r[valueKey]) * num(r.cost_per_uom), members: [r.syt_code], grouped: false,
    search: `${r.syt_code} ${r.generic_code ?? ''} ${r.product_name}`.toLowerCase(),
  });
  const order: (string | T)[] = [];
  const buckets = new Map<string, T[]>();
  for (const r of rows) {
    const g = (r.generic_code ?? '').trim();
    if (!g || !enabled) { order.push(r); continue; }
    if (!buckets.has(g)) { buckets.set(g, []); order.push(g); }
    buckets.get(g)!.push(r);
  }
  const out: Grouped<T>[] = [];
  for (const o of order) {
    if (typeof o !== 'string') { out.push(single(o)); continue; }
    const list = [...buckets.get(o)!].sort((a, b) => a.syt_code.localeCompare(b.syt_code));
    if (list.length === 1) { out.push(single(list[0])); continue; }
    // الاسم: آخر حجم اتشترى، وإلا أول واحد بالترتيب
    const rep = list.find((r) => r.syt_code === preferred[o]) ?? list[0];
    const sums: Record<string, number> = {};
    for (const k of qtyKeys) sums[k] = r4(list.reduce((s, r) => s + num(r[k]), 0));
    const value = list.reduce((s, r) => s + num(r[valueKey]) * num(r.cost_per_uom), 0);
    const q = sums[valueKey] ?? 0;
    const g: Grouped<T> = {
      ...rep, ...sums,
      product_id: `generic:${o}`, syt_code: o, generic_code: o, uom_factor: 1,
      // متوسط التكلفة المرجّح، وإلا تكلفة الحجم المختار لو الكمية صفر
      cost_per_uom: q !== 0 ? value / q : num(rep.cost_per_uom),
      value, members: list.map((r) => r.syt_code), grouped: true,
      search: `${o} ${list.map((r) => `${r.syt_code} ${r.product_name}`).join(' ')}`.toLowerCase(),
    };
    out.push(g);
  }
  return out;
}

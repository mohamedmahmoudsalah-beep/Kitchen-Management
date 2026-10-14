import { describe, expect, it } from 'vitest';
import { groupByGeneric, type GRow } from '@/lib/group-generic';

const mk = (syt: string, gen: string | null, name: string, f: number, cost: number, o: Record<string, number>): GRow => ({
  product_id: syt, syt_code: syt, generic_code: gen, product_name: name, category: null, uom_factor: f, cost_per_uom: cost, ...o,
});
const KEYS = ['opening', 'purchases', 'consumption'];

describe('groupByGeneric', () => {
  const rows = [
    mk('RM0500-A', 'RM0500', 'olives A', 1, 157.4, { opening: 5.35, purchases: 0, consumption: 5.35 }),
    mk('RM0500-B', 'RM0500', 'olives B', 0.36, 430.7, { opening: 0, purchases: 17.28, consumption: 17.28 }),
    mk('X1', 'X', 'solo', 2, 10, { opening: 4, purchases: 0, consumption: 4 }),
    mk('N1', null, 'no generic', 1, 5, { opening: 1, purchases: 0, consumption: 1 }),
  ];
  it('sums quantities per generic code and keeps single/no-generic rows as they are', () => {
    const g = groupByGeneric(rows, KEYS, 'consumption');
    expect(g).toHaveLength(3);
    const olives = g.find((r) => r.generic_code === 'RM0500')!;
    expect(olives.grouped).toBe(true);
    expect(olives.opening).toBe(5.35);
    expect(olives.purchases).toBe(17.28);
    expect(olives.consumption).toBe(22.63);
    expect(olives.uom_factor).toBe(1);
    expect(olives.members).toEqual(['RM0500-A', 'RM0500-B']);
    expect(g.find((r) => r.syt_code === 'X1')!.grouped).toBe(false);   // generic فيه حجم واحد
    expect(g.find((r) => r.syt_code === 'N1')!.grouped).toBe(false);   // من غير generic
  });
  it('value = sum of each size at its own cost', () => {
    const olives = groupByGeneric(rows, KEYS, 'consumption').find((r) => r.generic_code === 'RM0500')!;
    expect(olives.value).toBeCloseTo(5.35 * 157.4 + 17.28 * 430.7, 6);
  });
  it('name from last purchased size, else first by Syt Code', () => {
    expect(groupByGeneric(rows, KEYS, 'consumption', { RM0500: 'RM0500-B' }).find((r) => r.generic_code === 'RM0500')!.product_name).toBe('olives B');
    expect(groupByGeneric(rows, KEYS, 'consumption').find((r) => r.generic_code === 'RM0500')!.product_name).toBe('olives A');
    expect(groupByGeneric(rows, KEYS, 'consumption', { RM0500: 'ZZZ' }).find((r) => r.generic_code === 'RM0500')!.product_name).toBe('olives A');
  });
  it('search text covers every member size', () => {
    const olives = groupByGeneric(rows, KEYS, 'consumption').find((r) => r.generic_code === 'RM0500')!;
    expect(olives.search).toContain('rm0500-b');
    expect(olives.search).toContain('olives b');
  });
});

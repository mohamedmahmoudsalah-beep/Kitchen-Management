import { describe, expect, it } from 'vitest';
import { applyChoices, findAmbiguous, type Prod } from '@/lib/import/ambiguous';
import { monthRange } from '@/lib/months';
import { reportTable } from '@/lib/archive';
import { buildDocTable, type ExportDoc, type ExportLine } from '@/lib/doc-export';

const p = (id: string, syt: string, gen: string | null, f = 1, active = true): Prod => ({ id, syt_code: syt, generic_code: gen, name: `P ${syt}`, uom_factor: f, is_active: active });

describe('ambiguous generic codes', () => {
  const prods = [p('1', 'S1', 'G1', 1), p('2', 'S2', 'G1', 5), p('3', 'S3', 'G2'), p('4', 'S4', 'G3', 1), p('5', 'S5', 'G3', 2, false)];
  const rows = [{ code: 'G1', qty: 1 }, { code: 'G1', qty: 2 }, { code: 'G2', qty: 3 }, { code: 'S1', qty: 4 }];
  it('flags only codes that match more than one product', () => {
    const a = findAmbiguous(rows, prods);
    expect(a.map((x) => x.code)).toEqual(['G1']);
    expect(a[0].rowCount).toBe(2);
    expect(a[0].options.map((o) => o.syt_code)).toEqual(['S1', 'S2']);
  });
  it('lists only active sizes in the options', () => {
    const a = findAmbiguous([{ code: 'G3' }], prods);
    expect(a[0].options.map((o) => o.syt_code)).toEqual(['S4']);
  });
  it('applies the chosen Syt code to every row with that code', () => {
    const out = applyChoices(rows, { G1: 'S2' });
    expect(out.map((r) => r.code)).toEqual(['S2', 'S2', 'G2', 'S1']);
    expect(rows[0].code).toBe('G1');
  });
});

describe('month ranges', () => {
  it('gives the first and last day of full months', () => {
    expect(monthRange('2026-05', '2026-06')).toEqual({ from: '2026-05-01', to: '2026-06-30' });
    expect(monthRange('2028-02', '2028-02')).toEqual({ from: '2028-02-01', to: '2028-02-29' });
  });
  it('rejects reversed or empty input', () => {
    expect(monthRange('2026-06', '2026-05')).toBeNull();
    expect(monthRange('', '2026-05')).toBeNull();
  });
});

describe('archive tables', () => {
  it('report table has value at current cost', () => {
    const t = reportTable('consumption', [{ syt_code: 'A', generic_code: null, product_name: 'x', category: null, uom_factor: 2, cost_per_uom: 3, opening: 1, consumption: 4 }]);
    expect(t.rows[0][t.headers.indexOf('= Consumption')]).toBe(4);
    expect(t.rows[0][t.headers.indexOf('Value @ current cost')]).toBe(12);
  });
  it('multi-kitchen document export names the kitchen per document', () => {
    const docs: ExportDoc[] = [
      { id: 'a', doc_no: 'P1', doc_date: '2026-05-01', status: 'POSTED', note: null, kitchen_id: 'k1' },
      { id: 'b', doc_no: 'P2', doc_date: '2026-05-02', status: 'POSTED', note: null, kitchen_id: 'k2' },
    ];
    const line = (d: string): ExportLine => ({ document_id: d, line_no: 1, qty_input: 1, input_mode: 'BASE', qty_pieces: 1, qty_base: 1, reason: null, note: null,
      uom_factor_snapshot: 1, unit_cost_snapshot: 1, products: { syt_code: 'A', generic_code: null, name: 'n', category: null, uom_name: null }, transfer_lines: null });
    const t = buildDocTable('PURCHASE', docs, [line('a'), line('b')], { kitchenName: '', kitchenNameOf: (id) => (id === 'k1' ? 'Maadi' : 'Rehab') });
    expect(t.rows.map((r) => r[t.headers.indexOf('Kitchen')])).toEqual(['Maadi', 'Rehab']);
  });
});

import { describe, expect, it } from 'vitest';
import { buildDocTable, type ExportDoc, type ExportLine } from '@/lib/doc-export';

const prod = { syt_code: 'A1', generic_code: 'G1', name: 'Flour', category: 'Dry', uom_name: 'kg' };
const line = (o: Partial<ExportLine>): ExportLine => ({
  document_id: 'd1', line_no: 1, qty_input: 2, input_mode: 'PIECE', qty_pieces: 2, qty_base: 10, reason: null, note: null,
  uom_factor_snapshot: 5, unit_cost_snapshot: 3, products: prod, transfer_lines: null, ...o,
});
const doc = (o: Partial<ExportDoc> = {}): ExportDoc => ({ id: 'd1', doc_no: 'PUR-1', doc_date: '2027-01-01', status: 'POSTED', note: 'n', ...o });

describe('line-level document export', () => {
  it('writes one row per product line with doc columns repeated', () => {
    const t = buildDocTable('PURCHASE', [doc()], [line({}), line({ line_no: 2, qty_base: 5, qty_pieces: 1 })], { kitchenName: 'Maadi' });
    expect(t.rows).toHaveLength(2);
    expect(t.headers.slice(0, 7)).toEqual(['Doc No', 'Date', 'Status', 'Kitchen', 'Lines', 'Note', 'Override reason']);
    expect(t.rows[0].slice(0, 6)).toEqual(['PUR-1', '2027-01-01', 'POSTED', 'Maadi', 2, 'n']);
    expect(t.rows[1][t.headers.indexOf('Qty (base)')]).toBe(5);
    expect(t.rows[0][t.headers.indexOf('Line value')]).toBe(30);
  });
  it('keeps a document without lines as one empty row', () => {
    const t = buildDocTable('WASTE', [doc({ document_lines: [{ count: 0 }] })], [], { kitchenName: 'Maadi' });
    expect(t.rows).toHaveLength(1);
    expect(t.rows[0].every((c, i) => i < 7 || c === null)).toBe(true);
  });
  it('adjustments carry the effect from the sign', () => {
    const t = buildDocTable('ADJUSTMENT', [doc()], [line({ qty_base: -4 })], { kitchenName: 'M' });
    expect(t.rows[0][t.headers.indexOf('Effect')]).toBe('Decrease');
  });
  it('transfers export sent / received / returned / pending with kitchen names', () => {
    const d = doc({ kitchen_id: 'k1', counterpart_kitchen_id: 'k2' });
    const l = line({ transfer_lines: [{ sent_base: 10, received_base: 7, returned_base: 1 }] });
    const t = buildDocTable('TRANSFER', [d], [l], { kitchenName: 'x', kitchenNameOf: (id) => (id === 'k1' ? 'Rehab' : 'Maadi') });
    const r = t.rows[0]; const h = t.headers;
    expect(r[h.indexOf('From')]).toBe('Rehab'); expect(r[h.indexOf('To')]).toBe('Maadi');
    expect([r[h.indexOf('Sent (base)')], r[h.indexOf('Received (base)')], r[h.indexOf('Returned (base)')], r[h.indexOf('Pending return (base)')]]).toEqual([10, 7, 1, 2]);
  });
});

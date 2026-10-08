import { describe, expect, it } from 'vitest';
import { MODULES, mapRows, normalizeDate, normalizeNumber, normalizeCode, normHeader } from '@/lib/import/columns';
import { toCsv } from '@/lib/export';

describe('normalizeDate', () => {
  it('handles ISO, day-first and serials', () => {
    expect(normalizeDate('2026-10-01')).toBe('2026-10-01');
    expect(normalizeDate('01/10/2026')).toBe('2026-10-01');     // يوم/شهر/سنة
    expect(normalizeDate('1-2-2026')).toBe('2026-02-01');
    expect(normalizeDate('2026-10-01 14:30:00')).toBe('2026-10-01');
    expect(normalizeDate('٠١/١٠/٢٠٢٦')).toBe('2026-10-01');
    expect(normalizeDate(46296)).toBe('2026-10-01');             // Excel serial
    expect(normalizeDate(new Date(Date.UTC(2026, 9, 1)))).toBe('2026-10-01');
  });
  it('keeps invalid dates as text so the DB reports the row', () => {
    expect(normalizeDate('31/02/2026')).toBe('31/02/2026');
    expect(normalizeDate('abc')).toBe('abc');
    expect(normalizeDate('')).toBe('');
  });
});

describe('normalizeNumber / normalizeCode', () => {
  it('normalizes numbers', () => {
    expect(normalizeNumber(5)).toBe('5');
    expect(normalizeNumber(0.1 + 0.2)).toBe('0.3');
    expect(normalizeNumber('1,234.50')).toBe('1234.50');
    expect(normalizeNumber('12,5')).toBe('12.5');
    expect(normalizeNumber('١٢٫٥')).toBe('12.5');
    expect(normalizeNumber(' 7 ')).toBe('7');
    expect(normalizeNumber('abc')).toBe('abc');
  });
  it('codes keep text, numeric codes lose .0', () => {
    expect(normalizeCode(1001)).toBe('1001');
    expect(normalizeCode('1001.0')).toBe('1001');
    expect(normalizeCode(' AB-1 ')).toBe('AB-1');
    expect(normalizeCode('0012')).toBe('0012');
  });
});

describe('mapRows', () => {
  it('reads columns by name, ignores extras, any order', () => {
    const table = [
      ['Extra', 'QTY', 'Syt Code', 'date', 'Whatever'],
      ['x', 3, 'S1', '01/10/2026', 'y'],
      [null, null, null, null, null],
      ['x', '2', 12345, new Date(Date.UTC(2026, 9, 2)), ''],
    ];
    const r = mapRows(table, MODULES.purchases);
    expect(r.missing).toEqual([]);
    expect(r.ignored.sort()).toEqual(['Extra', 'Whatever']);
    expect(r.rows).toEqual([
      { row_no: 2, data: { date: '2026-10-01', code: 'S1', qty: '3' } },
      { row_no: 4, data: { date: '2026-10-02', code: '12345', qty: '2' } },   // الصف الفاضي اتخطى ورقم الصف زي الملف
    ]);
  });
  it('prefers Syt over Generic when both columns exist', () => {
    const table = [['Generic Code', 'Syt Code', 'Date', 'Qty'], ['G1', '', '2026-10-01', 1], ['G2', 'S2', '2026-10-01', 1]];
    const r = mapRows(table, MODULES.waste);
    expect(r.rows.map((x) => x.data.code)).toEqual(['G1', 'S2']);
  });
  it('reports missing required columns', () => {
    expect(mapRows([['Date', 'Qty']], MODULES.opening).missing).toEqual(['code']);
    expect(mapRows([['Date', 'Code']], MODULES.opening).missing).toEqual(['qty']);
    expect(mapRows([['Date', 'Code', 'Qty']], MODULES.adjustments).missing).toEqual(['reason']);
    expect(mapRows([['Date', 'Code', 'Qty']], MODULES.waste).missing).toEqual(['reason']);
    expect(mapRows([['Date', 'Code']], MODULES.closing).missing).toEqual(['qty']);
    expect(mapRows([['Product Name', 'Cost']], MODULES.products).missing).toEqual(['syt_code']);
  });
  it('maps the real Odoo Data Product headers', () => {
    const r = mapRows([
      ['Syt Code', 'Generic Code', 'Product Name', 'UoM', 'Product/Financial Category', 'Cost', 'Cost Pr UOM'],
      [1001, 'G1', 'Flour 5kg', 'Unit', 'Dry', '52,5', 10.5],
    ], MODULES.products);
    expect(r.missing).toEqual([]);
    expect(r.ignored).toEqual([]);
    expect(r.rows[0].data).toEqual({
      syt_code: '1001', generic_code: 'G1', name: 'Flour 5kg', uom_name: 'Unit', category: 'Dry', cost: '52.5', cost_per_uom: '10.5',
    });
  });
  it('closing allows a zero count and maps like other tx modules', () => {
    const r = mapRows([['Date', 'Syt Code', 'Counted Qty', 'Qty'], ['2026-12-31', 'T1', 9, 0]], MODULES.closing);
    expect(r.rows[0].data).toEqual({ date: '2026-12-31', code: 'T1', qty: '0' });
  });
  it('maps Base Qty per Syt and accepts alternative headers', () => {
    const r = mapRows([['System Code', 'Name', 'Conversion', 'Cost/UOM'], ['S1', 'Rice', 3, 9]], MODULES.products);
    expect(r.rows[0].data).toEqual({ syt_code: 'S1', name: 'Rice', factor: '3', cost_per_uom: '9' });
  });
  it('normHeader strips spaces/symbols/case', () => {
    expect(normHeader(' Syt_Code ')).toBe('sytcode');
    expect(normHeader('Qty (Base)')).toBe('qtybase');
  });
});

describe('toCsv', () => {
  it('adds BOM and escapes', () => {
    const c = toCsv(['a', 'b'], [['x,y', 'عربي "q"']]);
    expect(c.startsWith('\uFEFF')).toBe(true);
    expect(c).toContain('"x,y","عربي ""q"""');
  });
});

import { describe, expect, it } from 'vitest';
import { decodeText, normKitchen, parseSalesDate, parseSalesTable } from '@/lib/sales-file';
import { parseBomTable, plainNum } from '@/lib/bom-file';
import { MODULE_ORDER } from '@/lib/import/columns';
import { NAV_GROUPS, PAGE_HREF, HIDDEN_PAGES, GLOBAL_PAGES } from '@/lib/nav';
import { reportTable } from '@/lib/archive';

const HEAD = ['Delivered At', 'Yelo Order ID', 'Breadfast Kitchen Name', 'Product ID', 'Product Name', 'Product Type', 'Order Product Quantity'];

describe('sales dates (month/day/year, as in the BI export)', () => {
  it('reads 11/04/26 as 4 November 2026', () => expect(parseSalesDate('11/04/26')).toBe('2026-11-04'));
  it('reads other usual shapes', () => {
    expect(parseSalesDate('2026-11-04')).toBe('2026-11-04');
    expect(parseSalesDate('2026-11-04 13:20:00')).toBe('2026-11-04');
    expect(parseSalesDate('11/4/2026')).toBe('2026-11-04');
    expect(parseSalesDate('25/12/26')).toBe('2026-12-25');          // الرقم الأول > 12 = يوم
    expect(parseSalesDate(new Date(Date.UTC(2026, 10, 4)))).toBe('2026-11-04');
    expect(parseSalesDate(46330)).toBe('2026-11-04');               // رقم Excel
  });
  it('rejects nonsense', () => {
    expect(parseSalesDate('13/13/26')).toBeNull();
    expect(parseSalesDate('02/30/26')).toBeNull();
    expect(parseSalesDate('')).toBeNull();
    expect(parseSalesDate('soon')).toBeNull();
  });
});

describe('sales file parsing', () => {
  const table = [HEAD,
    ['11/04/26', '#1', 'Maadi Kitchen', '11633', 'Chicken Parm Bagel', 'product', '1'],
    ['11/04/26', '#2', 'Maadi Kitchen', 11633, 'Chicken Parm Bagel', 'product', '2'],
    ['11/04/26', '#2', 'Maadi Kitchen', '9001', 'Without Jalapeños', 'modifier', '1'],
    ['11/05/26', '#3', ' maadi   kitchen ', '11633', 'Chicken Parm Bagel', 'product', '4'],
    ['11/04/26', '#4', 'New Cairo FP #7 Kitchen', '1-1111', 'Text id product', 'product', '1,000'],
    ['bad-date', '#5', 'Maadi Kitchen', '11633', 'x', 'product', '1'],
    ['11/04/26', '#6', '', '11633', 'x', 'product', '1'],
    ['11/04/26', '#7', 'Maadi Kitchen', '11633', 'x', 'product', 'abc'],
    [null, null, null, null, null, null, null]];
  const r = parseSalesTable(table);
  it('ignores modifiers and counts them', () => { expect(r.modifiers).toBe(1); expect(r.rows).toBe(4); });
  it('groups kitchen x day x product (summing quantities, numeric and text ids alike)', () => {
    const d4 = r.groups.find((g) => g.kitchenKey === 'maadi kitchen' && g.date === '2026-11-04')!;
    expect(d4.rows).toEqual([{ pid: '11633', name: 'Chicken Parm Bagel', qty: 3 }]);
    expect(r.groups.find((g) => g.date === '2026-11-05')!.rows[0].qty).toBe(4);
    expect(r.groups.find((g) => g.kitchenKey.startsWith('new cairo'))!.rows[0]).toEqual({ pid: '1-1111', name: 'Text id product', qty: 1000 });
  });
  it('normalises kitchen names so spacing/case never splits a kitchen', () => {
    expect(normKitchen('  Maadi   Kitchen ')).toBe('maadi kitchen');
    expect(r.kitchens.map((k) => k.key)).toEqual(['maadi kitchen', 'new cairo fp #7 kitchen']);
    expect(r.kitchens[0].days).toBe(2);
  });
  it('reports bad rows instead of dropping them silently', () => {
    expect(r.bad.map((b) => b.row)).toEqual([7, 8, 9]);
    expect(r.dates).toEqual({ min: '2026-11-04', max: '2026-11-05' });
    expect(r.months).toEqual(['2026-11']);
  });
  it('fails with a clear message when columns are missing', () => {
    expect(() => parseSalesTable([['a', 'b'], ['1', '2']])).toThrow(/Product ID/);
    expect(() => parseSalesTable([['Product ID', 'Order Product Quantity'], ['1', '2']])).toThrow(/Delivered At/);
  });
});

describe('UTF-16 export decoding', () => {
  it('decodes UTF-16LE with BOM (the BI export) and plain UTF-8', () => {
    const s = 'Product ID\tName\n11\tPizza حار';
    const u16 = new Uint8Array(2 + s.length * 2); u16[0] = 0xff; u16[1] = 0xfe;
    for (let i = 0; i < s.length; i++) { u16[2 + i * 2] = s.charCodeAt(i) & 255; u16[3 + i * 2] = s.charCodeAt(i) >> 8; }
    expect(decodeText(u16.buffer)).toBe(s);
    expect(decodeText(new TextEncoder().encode(s).buffer as ArrayBuffer)).toBe(s);
  });
});

describe('BOM file parsing', () => {
  const H = ['Product ID', 'Description Product', 'Semi Name', 'Catgry', 'RM Code', 'Ingredients', 'Unit', 'Recipe', 'Waste %', 'Recipe Include  Waste'];
  const r = parseBomTable([H,
    ['1', 'Wrap', 'Arugula', 'RM', 'rmf-0002', 'Arugula', 'KG', 0.006, 0.5, 0.012],
    [1, 'Wrap', 'Sauce', 'RM', 'RMF-0002', 'Arugula', 'KG', 0.01, 0, 0.01],
    ['1-1111', 'Text id', 'Box', 'PK', 191, 'Box', 'Pcs', 1, 0, 1],
    ['2', 'Zero', 'x', 'RM', 'RM1', 'x', 'KG', 0, 0, 0],
    ['', '', '', '', '', '', '', '', '', ''],
    ['3', 'Missing code', '', 'RM', '', '', 'KG', 1, 0, 1]]);
  it('uses the "Recipe Include  Waste" column, upper-cases RM codes and keeps text ids', () => {
    expect(r.rows[0]).toMatchObject({ fid: '1', rm: 'RMF-0002', qty: '0.012', unit: 'KG', cat: 'RM' });
    expect(r.rows[2]).toMatchObject({ fid: '1-1111', rm: '191', qty: '1', unit: 'Pcs' });
  });
  it('counts products, rm codes, non-positive and unusable rows', () => {
    expect(r.products).toBe(3); expect(r.rmCodes).toBe(3); expect(r.nonPositive).toBe(1); expect(r.skipped).toBe(1);
  });
  it('never sends scientific notation (the server cannot read 5e-7)', () => {
    expect(plainNum(0.0000005)).toBe('0.0000005'); expect(plainNum(0.012)).toBe('0.012'); expect(plainNum(2)).toBe('2'); expect(plainNum(0.25)).toBe('0.25');
    expect(plainNum(1e-12)).toBe('0');
  });
  it('fails clearly when the recipe column is missing', () => {
    expect(() => parseBomTable([['Product ID', 'RM Code', 'Recipe'], ['1', 'X', 1]])).toThrow(/Recipe Include/);
  });
});

describe('navigation after this batch', () => {
  it('Sales and BOM are pages, Warehouse Transactions is gone from the UI', () => {
    const keys = NAV_GROUPS.flatMap((g) => g.keys);
    expect(keys).toContain('sales'); expect(keys).toContain('bom');
    expect(keys).not.toContain('warehouse_transactions');
    expect(PAGE_HREF.sales).toBe('/sales'); expect(PAGE_HREF.bom).toBe('/bom');
    expect(HIDDEN_PAGES.has('warehouse_transactions')).toBe(true);
    expect(GLOBAL_PAGES.has('bom')).toBe(true);
    expect(MODULE_ORDER).not.toContain('wh_txn' as never);
    for (const k of keys) expect(PAGE_HREF[k], k).toBeTruthy();
  });
});

describe('report exports carry the new columns', () => {
  it('stock export has the sales column and consumption has variance', () => {
    const base = { syt_code: 'A', generic_code: 'G', product_name: 'x', category: null, uom_factor: 1, cost_per_uom: 2, opening: 1 };
    expect(reportTable('stock', [{ ...base, sales_rm: 3, closing_book: 1 }]).headers).toContain('− Sales (BOM)');
    const c = reportTable('consumption', [{ ...base, consumption: 5, sales_consumption: 4, variance: 1 }]);
    expect(c.headers).toEqual(expect.arrayContaining(['From sales (BOM)', 'Variance (actual − sales)']));
    expect(c.rows[0]).toContain(4);
  });
});

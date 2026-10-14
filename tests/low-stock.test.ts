import { describe, expect, it } from 'vitest';
import { levelsFromTable, stockStatus } from '@/lib/low-stock';

describe('stockStatus', () => {
  it('uses <= low and >= high, avg in between', () => {
    expect(stockStatus(5, 10, 50)).toBe('LOW'); expect(stockStatus(10, 10, 50)).toBe('LOW');
    expect(stockStatus(11, 10, 50)).toBe('AVG'); expect(stockStatus(49.9, 10, 50)).toBe('AVG');
    expect(stockStatus(50, 10, 50)).toBe('HIGH'); expect(stockStatus(500, 10, 50)).toBe('HIGH');
    expect(stockStatus(0, 0, 5)).toBe('LOW');
  });
  it('no levels = NOT_SET', () => {
    expect(stockStatus(5, null, null)).toBe('NOT_SET'); expect(stockStatus(5, undefined, 10)).toBe('NOT_SET');
  });
});

describe('levelsFromTable', () => {
  it('reads by header name (any order, extra columns ignored), keeps file row numbers', () => {
    const t = [['Product', 'High Stock', 'Code', 'Low Stock'], ['olives', 50, 'RM0500', '10'], [], ['x', '1,200', 12568369.0, 3]];
    const f = levelsFromTable(t);
    expect(f.missing).toEqual([]);
    expect(f.ignored).toEqual(['Product']);
    expect(f.rows).toEqual([{ row: 2, code: 'RM0500', low: '10', high: '50' }, { row: 4, code: '12568369', low: '3', high: '1200' }]);
  });
  it('accepts Arabic/alias headers and reports missing columns', () => {
    expect(levelsFromTable([['الكود', 'Min', 'Max'], ['A', 1, 2]]).rows[0]).toEqual({ row: 2, code: 'A', low: '1', high: '2' });
    expect(levelsFromTable([['Code', 'Low Stock'], ['A', 1]]).missing).toEqual(['high']);
    expect(levelsFromTable([]).missing).toEqual(['code', 'low', 'high']);
  });
});

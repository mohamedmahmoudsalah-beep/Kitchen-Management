import { describe, expect, it } from 'vitest';
import writeExcelFile from 'write-excel-file/node';
import { readSheet } from 'read-excel-file/node';
import { MODULES, mapRows } from '@/lib/import/columns';

// بيتأكد إن التواريخ والأرقام اللي جاية من ملف xlsx حقيقي بتتقرا صح
describe('xlsx roundtrip', () => {
  it('date cells survive in any timezone', async () => {
    const buf = await writeExcelFile([
      [{ value: 'Date' }, { value: 'Code' }, { value: 'Qty' }],
      [{ value: new Date(Date.UTC(2026, 9, 1)), format: 'yyyy-mm-dd' }, { value: 'S1' }, { value: 4 }],
      [{ value: new Date(Date.UTC(2026, 9, 2)), format: 'dd/mm/yyyy' }, { value: 'S2' }, { value: 2.5 }],
    ] as never).toBuffer();
    const table = (await readSheet(buf as never)) as unknown[][];
    const r = mapRows(table, MODULES.purchases);
    expect(r.missing).toEqual([]);
    expect(r.rows.map((x) => x.data.date)).toEqual(['2026-10-01', '2026-10-02']);
    expect(r.rows.map((x) => x.data.qty)).toEqual(['4', '2.5']);
  });
});

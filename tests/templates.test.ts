import { describe, expect, it } from 'vitest';
import writeExcelFile from 'write-excel-file/node';
import { readSheet } from 'read-excel-file/node';
import { MODULES, MODULE_ORDER, mapRows } from '@/lib/import/columns';
import { NOTES, buildTemplateRows, sampleItems } from '@/lib/import/templates';

// القالب اللي بنحمّله لازم الـ Importer نفسه يقبله من غير أي عمود ناقص
describe('Excel templates', () => {
  for (const m of MODULE_ORDER) {
    it(`${m}: template headers + sample rows are accepted by the importer`, async () => {
      const spec = MODULES[m];
      const rows = buildTemplateRows(m, sampleItems(null), '2026-12-01', 'Maadi');
      const buf = await writeExcelFile([spec.template.map((h) => ({ value: h })), ...rows.map((r) => r.map((v) => (v === null ? null : { value: v })))] as never).toBuffer();
      const table = (await readSheet(buf as never)) as unknown[][];
      const mapped = mapRows(table, spec);
      expect(mapped.missing).toEqual([]);
      expect(mapped.ignored).toEqual([]);
      expect(mapped.rows).toHaveLength(3);
      expect(NOTES[m].length).toBeGreaterThan(0);
    });
  }
  it('transfers sample carries a receiving kitchen and adjustments carry signed qty with reasons', () => {
    const t = buildTemplateRows('transfers', sampleItems(null), '2026-12-01', 'Maadi');
    expect(t.every((r) => r[1] === 'Maadi')).toBe(true);
    const a = buildTemplateRows('adjustments', sampleItems(null), '2026-12-01', 'Maadi');
    expect(a.map((r) => [Number(r[2]) > 0, r[3]])).toEqual([[true, 'Overage'], [false, 'Missing'], [false, 'Missing']]);
  });
});

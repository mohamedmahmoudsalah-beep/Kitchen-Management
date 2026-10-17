import { describe, expect, it } from 'vitest';
import { neutralizeFormula, toCsv } from '@/lib/export';
import { MAX_FILE_BYTES, readTable } from '@/lib/import/parse-file';

describe('CSV formula injection', () => {
  it('neutralizes text that Excel would run as a formula', () => {
    for (const bad of ['=HYPERLINK("http://evil","x")', '+cmd|calc', '-2+3', '@SUM(A1)', '\t=1', '\r=1', '=1+1'])
      expect(neutralizeFormula(bad)).toBe(`'${bad}`);
  });
  it('keeps normal text and real numbers untouched', () => {
    for (const ok of ['Stretch Roll', 'RM0500-A', '', '12', '-5', '+3.5', '-0.25', '1e3', '.5', 'ملح', 'a=b', '5-3'])
      expect(neutralizeFormula(ok)).toBe(ok);
  });
  it('toCsv applies it to string cells only (numbers stay numbers)', () => {
    const csv = toCsv(['Name', 'Qty'], [['=BAD()', -5], ['ok', 3]]);
    expect(csv).toContain("'=BAD()");
    expect(csv).toContain(',-5');
    expect(csv).not.toContain("'-5");
  });
  it('quotes still work after neutralizing', () => {
    expect(toCsv(['A'], [['=a,b']])).toContain('"\'=a,b"');
  });
});

describe('file size cap', () => {
  it('rejects files over the limit before parsing', async () => {
    const big = new File([new Uint8Array(MAX_FILE_BYTES + 1)], 'big.xlsx');
    await expect(readTable(big)).rejects.toThrow('15 MB');
  });
});

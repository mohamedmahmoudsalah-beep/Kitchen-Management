import { describe, expect, it } from 'vitest';
import { hasArabic, isRtlText, shapeText, wrapLogical } from '@/lib/pdf/shape';
import { buildPdf, pdfName } from '@/lib/pdf/builder';
import { documentSpec } from '@/lib/pdf/documents';
import { isSheetFile, setPendingImportFile, takePendingImportFile } from '@/lib/import/handoff';

describe('Arabic shaping for PDF', () => {
  it('leaves Latin text alone', () => {
    expect(shapeText('RM0500-A Olives (680 gm)')).toBe('RM0500-A Olives (680 gm)');
    expect(hasArabic('abc')).toBe(false); expect(hasArabic('سلام')).toBe(true);
  });
  it('detects paragraph direction by the first strong character', () => {
    expect(isRtlText('سلام world')).toBe(true); expect(isRtlText('world سلام')).toBe(false); expect(isRtlText('123 ...')).toBe(false);
  });
  it('shapes Arabic into joined forms in visual order (not the raw input)', () => {
    const out = shapeText('كتاب');
    expect(out).not.toBe('كتاب'); expect(Array.from(out)).toHaveLength(4);
    // الترتيب البصري: أول حرف معروض هو آخر حرف منطقي (الباء المنفصلة بعد الألف)، وآخر حرف معروض هو الكاف بشكلها الابتدائي
    expect(out.charCodeAt(0)).toBe(0x0628);
    expect(out.charCodeAt(3)).toBe(0xFEDB);
  });
  it('joins lam + alef into the single ligature', () => {
    expect(Array.from(shapeText('لا'))).toHaveLength(1);
  });
  it('mixed text keeps Latin runs readable and in order', () => {
    const out = shapeText('طلب PK1044 جديد');
    expect(out).toContain('PK1044');
  });
  it('does not emit presentation forms the embedded font lacks (isolated forms fall back to base letters)', () => {
    for (const ch of Array.from(shapeText('أكياس الرطوبة آمن ؤ ئ'))) {
      const c = ch.charCodeAt(0);
      // الأشكال المنفصلة في FE80–FEFF الناقصة من Cairo بتتحوّل لحرف أساسي (0600–06FF)
      expect([0xFE80, 0xFE81, 0xFE83, 0xFE85, 0xFE87, 0xFE89, 0xFE8D, 0xFE8F, 0xFE93, 0xFE95]).not.toContain(c);
    }
  });
});

describe('wrapLogical', () => {
  const m = (s: string) => s.length;
  it('wraps on words and keeps blank lines', () => {
    expect(wrapLogical('aaa bbb ccc', 7, m)).toEqual(['aaa bbb', 'ccc']);
    expect(wrapLogical('a\n\nb', 10, m)).toEqual(['a', '', 'b']);
    expect(wrapLogical('', 10, m)).toEqual(['']);
  });
  it('breaks a word that is wider than the column', () => {
    expect(wrapLogical('abcdefghij', 4, m)).toEqual(['abcd', 'efgh', 'ij']);
  });
  it('wraps Arabic in logical order (first line holds the first words)', () => {
    const lines = wrapLogical('استلام بضاعة من المورد', 12, m);
    expect(lines[0].startsWith('استلام')).toBe(true); expect(lines.join(' ')).toBe('استلام بضاعة من المورد');
  });
});

describe('buildPdf', () => {
  const spec = (n: number) => ({
    title: 'Test', meta: [['Kitchen', 'Maadi'], ['Note', 'استلام بضاعة']] as [string, string][],
    sections: [{ cols: [{ head: '#', w: 1 }, { head: 'Product', w: 6 }, { head: 'Qty', w: 2, align: 'right' as const }],
      rows: Array.from({ length: n }, (_, i) => [i + 1, i % 2 ? 'أكياس كرافت' : 'Kalamata Olives', i * 1.5]), foot: ['', 'Total', 1] }],
    signatures: ['Sender', 'Receiver'],
  });
  it('produces a real PDF and paginates long tables', async () => {
    const small = await buildPdf(spec(3)); const big = await buildPdf(spec(150));
    const head = new TextDecoder().decode((await small.arrayBuffer()).slice(0, 5));
    expect(head).toBe('%PDF-'); expect(big.size).toBeGreaterThan(small.size);
    const txt = new TextDecoder('latin1').decode(await big.arrayBuffer());
    expect((txt.match(/\/Type \/Page\b/g) ?? []).length).toBeGreaterThan(2);
  }, 30000);
  it('can be built twice in a row (library hooks removed only once)', async () => {
    await buildPdf(spec(2)); await expect(buildPdf(spec(2))).resolves.toBeInstanceOf(Blob);
  }, 30000);
  it('file names are safe', () => {
    expect(pdfName('PUR-000012')).toBe('PUR-000012.pdf');
    expect(pdfName('warehouse stock', 'MAADI', '2026/09')).toBe('warehouse_stock_MAADI_2026_09.pdf');
  });
});

describe('documentSpec', () => {
  const names = (id?: string | null) => (id === 'k1' ? 'Maadi' : id === 'k2' ? 'NC7' : '—');
  const base = { id: 'd', doc_no: 'PUR-000012', doc_type: 'PURCHASE', doc_date: '2026-10-02', status: 'POSTED', note: 'ملاحظة', kitchen_id: 'k1' };
  const line = (n: number, q: number, cost: number | null, extra = {}) => ({ line_no: n, qty_input: q, input_mode: 'BASE' as const, qty_pieces: q, qty_base: q, reason: null, note: null, uom_factor_snapshot: 1, unit_cost_snapshot: cost, products: { syt_code: `P${n}`, name: `Prod ${n}` }, transfer_lines: null, ...extra });
  it('purchase: totals qty and value at posting cost', () => {
    const s = documentSpec(base, [line(1, 10, 2.5), line(2, 4, 10)], names);
    expect(s.title).toBe('Purchase · PUR-000012');
    const foot = s.sections[0].foot!; expect(foot[3]).toBe('14'); expect(foot[6]).toBe('65');
    expect(s.signatures).toEqual(['Received by', 'Approved by']);
  });
  it('transfer: shows from/to and pending return', () => {
    const t = documentSpec({ ...base, doc_type: 'TRANSFER', doc_no: 'TRF-000003', status: 'RETURN_PENDING', counterpart_kitchen_id: 'k2' },
      [line(1, 100, null, { transfer_lines: { sent_base: 100, received_base: 50, returned_base: 20 } })], names);
    expect(t.meta?.slice(0, 2)).toEqual([['From', 'Maadi'], ['To', 'NC7']]);
    expect(t.sections[0].rows[0].slice(3, 7)).toEqual(['100', '50', '20', '30']);
    expect(t.signatures).toEqual(['Sender', 'Receiver']);
  });
  it('closing: explains it becomes the next opening', () => {
    expect(documentSpec({ ...base, doc_type: 'CLOSING' }, [line(1, 5, 1)], names).note).toContain('opening');
  });
});

describe('import handoff', () => {
  it('hands a file over exactly once', () => {
    const f = new File(['x'], 'a.xlsx'); setPendingImportFile(f);
    expect(takePendingImportFile()).toBe(f); expect(takePendingImportFile()).toBeNull();
  });
  it('accepts only sheets', () => {
    expect(isSheetFile(new File([''], 'a.xlsx'))).toBe(true); expect(isSheetFile(new File([''], 'b.CSV'))).toBe(true);
    expect(isSheetFile(new File([''], 'c.pdf'))).toBe(false); expect(isSheetFile(new File([''], 'd.exe'))).toBe(false);
  });
});

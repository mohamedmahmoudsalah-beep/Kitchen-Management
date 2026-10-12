import { describe, expect, it } from 'vitest';
import { crc32, makeZip } from '@/lib/zip';
import { tableCsv } from '@/lib/backup';

describe('zip writer', () => {
  it('crc32 matches the known check value', () => {
    expect(crc32(new TextEncoder().encode('123456789'))).toBe(0xcbf43926);
  });
  it('produces a zip with the right entry count and signatures', async () => {
    const enc = new TextEncoder();
    const blob = makeZip([{ name: 'a.csv', data: enc.encode('x,y\n1,2') }, { name: 'ب.csv', data: enc.encode('مرحبا') }]);
    const buf = new DataView(await blob.arrayBuffer());
    expect(buf.getUint32(0, true)).toBe(0x04034b50);
    expect(buf.getUint32(buf.byteLength - 22, true)).toBe(0x06054b50);
    expect(buf.getUint16(buf.byteLength - 22 + 10, true)).toBe(2);
  });
});

describe('backup csv', () => {
  it('serialises objects as JSON and keeps nulls empty', () => {
    const csv = tableCsv([{ id: 1, data: { a: 1 }, note: null }]);
    expect(csv).toContain('id,data,note');
    expect(csv).toContain('1,"{""a"":1}",');
  });
  it('empty table gives just a BOM', () => { expect(tableCsv([])).toBe('\uFEFF'); });
});

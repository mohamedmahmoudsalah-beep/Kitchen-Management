import Papa from 'papaparse';
import { readSheet } from 'read-excel-file/browser';

export const MAX_FILE_BYTES = 15 * 1024 * 1024;

// بيقرا CSV أو XLSX ويرجّع جدول (صفوف × أعمدة)
export async function readTable(file: File): Promise<unknown[][]> {
  if (file.size > MAX_FILE_BYTES) throw new Error('الملف أكبر من 15 MB — قسّمه على أكتر من ملف');
  const name = file.name.toLowerCase();
  if (name.endsWith('.xlsx')) {
    return (await readSheet(file)) as unknown[][];
  }
  if (name.endsWith('.csv') || name.endsWith('.txt')) {
    const text = (await file.text()).replace(/^\uFEFF/, '');
    const res = Papa.parse<string[]>(text, { skipEmptyLines: false });
    return res.data;
  }
  throw new Error('الملف لازم يكون .xlsx أو .csv');
}

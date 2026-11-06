import { readSheet } from 'read-excel-file/browser';
import { MAX_FILE_BYTES } from '@/lib/import/parse-file';

// ملف الـ BOM (BOMs_Hot_Food): صف لكل (منتج تام × Semi × RM). بناخد Recipe Include  Waste (كمية الـ RM للوحدة الواحدة من المنتج التام).
export type BomRow = { fid: string; fname: string; rm: string; qty: string; unit: string; cat: string };
export type ParsedBom = { rows: BomRow[]; sourceRows: number; products: number; rmCodes: number; nonPositive: number; skipped: number };

const norm = (s: unknown) => String(s ?? '').toLowerCase().replace(/[^a-z0-9\u0600-\u06ff]/g, '');
const HEADS = {
  fid: ['productid', 'fpid', 'finishedproductid', 'finishedid'],
  fname: ['descriptionproduct', 'productname', 'description', 'fpname'],
  rm: ['rmcode', 'rm', 'rmgenericcode', 'genericcode', 'ingredientcode'],
  qty: ['recipeincludewaste', 'recipeincludingwaste', 'recipewithwaste'],
  unit: ['unit', 'uom'],
  cat: ['catgry', 'category', 'cat'],
} as const;

// بدون صيغة علمية (1e-7) عشان السيرفر يفهمها. الـ DB بتحتفظ بـ 8 خانات عشرية.
export const plainNum = (n: number) => (Math.abs(n) < 1e-9 ? '0' : n.toFixed(8).replace(/\.?0+$/, ''));
const text = (v: unknown) => (v === null || v === undefined ? '' : typeof v === 'number' ? String(v) : String(v).trim());
function num(v: unknown): number | null {
  if (typeof v === 'number') return Number.isFinite(v) ? v : null;
  const s = String(v ?? '').trim().replace(/,/g, '');
  if (!s) return null;
  const n = Number(s);
  return Number.isFinite(n) ? n : null;
}

export function parseBomTable(table: unknown[][]): ParsedBom {
  let h = -1; const col: Partial<Record<keyof typeof HEADS, number>> = {};
  for (let i = 0; i < Math.min(table.length, 15); i++) {
    const heads = (table[i] ?? []).map(norm);
    const find = (k: keyof typeof HEADS) => heads.findIndex((x) => (HEADS[k] as readonly string[]).includes(x));
    if (find('fid') >= 0 && find('rm') >= 0 && find('qty') >= 0) {
      h = i; (Object.keys(HEADS) as (keyof typeof HEADS)[]).forEach((k) => { const ix = find(k); if (ix >= 0) col[k] = ix; });
      break;
    }
  }
  if (h < 0) throw new Error('مش لاقي أعمدة الـ BOM — لازم Product ID و RM Code و Recipe Include  Waste');
  const rows: BomRow[] = []; let skipped = 0; let nonPositive = 0;
  const prods = new Set<string>(); const rms = new Set<string>();
  for (let i = h + 1; i < table.length; i++) {
    const r = table[i] ?? [];
    if (r.every((c) => c === null || c === undefined || String(c).trim() === '')) continue;
    const fid = text(r[col.fid!]); const rm = text(r[col.rm!]).toUpperCase(); const q = num(r[col.qty!]);
    if (!fid || !rm) { skipped++; continue; }
    if (q === null || q <= 0) nonPositive++;
    rows.push({ fid, fname: col.fname === undefined ? '' : text(r[col.fname]), rm, qty: q === null ? '' : plainNum(q),
      unit: col.unit === undefined ? '' : text(r[col.unit]), cat: col.cat === undefined ? '' : text(r[col.cat]) });
    prods.add(fid); rms.add(rm);
  }
  return { rows, sourceRows: rows.length, products: prods.size, rmCodes: rms.size, nonPositive, skipped };
}

export async function readBomFile(file: File): Promise<ParsedBom> {
  if (file.size > MAX_FILE_BYTES) throw new Error('الملف أكبر من 15 MB');
  if (!file.name.toLowerCase().endsWith('.xlsx')) throw new Error('الـ BOM لازم يكون ملف .xlsx');
  return parseBomTable((await readSheet(file)) as unknown[][]);
}

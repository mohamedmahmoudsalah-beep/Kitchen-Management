import Papa from 'papaparse';
import { readSheet } from 'read-excel-file/browser';
import { MAX_FILE_BYTES } from '@/lib/import/parse-file';

// ملف المبيعات (Orders_Products_Raw_Data): صف لكل منتج في أوردر. بيتجمّع هنا (مطبخ × يوم × منتج) قبل الرفع.
export type SalesRow = { pid: string; name: string; qty: number };
export type SalesGroup = { kitchenName: string; kitchenKey: string; date: string; rows: SalesRow[]; units: number };
export type ParsedSales = {
  rows: number;                 // صفوف المنتجات اللي اتقرت (من غير الـ modifiers)
  modifiers: number;            // صفوف Modifier (Without X…) اتتجاهلت
  bad: { row: number; reason: string }[];
  groups: SalesGroup[];
  dates: { min: string; max: string } | null;
  months: string[];             // yyyy-mm
  kitchens: { name: string; key: string; days: number; units: number }[];
};

export const normKitchen = (s: string) => s.trim().replace(/\s+/g, ' ').toLowerCase();
const normHead = (s: unknown) => String(s ?? '').toLowerCase().replace(/[^a-z0-9\u0600-\u06ff]/g, '');

const HEADS = {
  date: ['deliveredat', 'date', 'deliverydate', 'orderdate', 'deliveredon'],
  kitchen: ['breadfastkitchenname', 'kitchenname', 'kitchen', 'branch', 'branchname'],
  pid: ['productid', 'productcode', 'itemid'],
  name: ['productname', 'product', 'itemname'],
  type: ['producttype', 'type', 'itemtype'],
  qty: ['orderproductquantity', 'quantity', 'qty', 'orderquantity'],
} as const;

const pad = (n: number) => String(n).padStart(2, '0');
const validYmd = (y: number, m: number, d: number) => {
  if (m < 1 || m > 12 || d < 1 || d > 31) return null;
  const dt = new Date(Date.UTC(y, m - 1, d));
  if (dt.getUTCFullYear() !== y || dt.getUTCMonth() !== m - 1 || dt.getUTCDate() !== d) return null;
  return `${y}-${pad(m)}-${pad(d)}`;
};

// m/d/yy (زي 11/04/26 = 4 نوفمبر 2026). لو الرقم الأول أكبر من 12 يتعامل كـ d/m. بيقبل كمان yyyy-mm-dd و Date و رقم Excel.
export function parseSalesDate(v: unknown): string | null {
  if (v instanceof Date && !Number.isNaN(v.getTime())) return `${v.getUTCFullYear()}-${pad(v.getUTCMonth() + 1)}-${pad(v.getUTCDate())}`;
  if (typeof v === 'number' && Number.isFinite(v) && v > 20000 && v < 80000) {
    const d = new Date(Math.round((v - 25569) * 86400000));
    return `${d.getUTCFullYear()}-${pad(d.getUTCMonth() + 1)}-${pad(d.getUTCDate())}`;
  }
  const s = String(v ?? '').trim();
  if (!s) return null;
  let m = /^(\d{4})-(\d{1,2})-(\d{1,2})(?:[ T].*)?$/.exec(s);
  if (m) return validYmd(+m[1], +m[2], +m[3]);
  m = /^(\d{1,2})[/.-](\d{1,2})[/.-](\d{2}|\d{4})(?:[ T].*)?$/.exec(s);
  if (!m) return null;
  const a = +m[1], b = +m[2];
  const y = m[3].length === 2 ? 2000 + +m[3] : +m[3];
  return a > 12 ? validYmd(y, b, a) : validYmd(y, a, b);
}

function toNum(v: unknown): number | null {
  if (typeof v === 'number') return Number.isFinite(v) ? v : null;
  const s = String(v ?? '').trim().replace(/,/g, '');
  if (s === '') return null;
  const n = Number(s);
  return Number.isFinite(n) ? n : null;
}
const cellText = (v: unknown) => {
  if (typeof v === 'number') return Number.isInteger(v) ? String(v) : String(v);
  return String(v ?? '').trim();
};

export function parseSalesTable(table: unknown[][]): ParsedSales {
  const empty: ParsedSales = { rows: 0, modifiers: 0, bad: [], groups: [], dates: null, months: [], kitchens: [] };
  // أول صف فيه Product ID + (Date أو Qty)
  let h = -1; const col: Partial<Record<keyof typeof HEADS, number>> = {};
  for (let i = 0; i < Math.min(table.length, 15); i++) {
    const heads = (table[i] ?? []).map(normHead);
    const find = (k: keyof typeof HEADS) => heads.findIndex((x) => (HEADS[k] as readonly string[]).includes(x));
    if (find('pid') >= 0 && find('qty') >= 0) {
      h = i;
      (Object.keys(HEADS) as (keyof typeof HEADS)[]).forEach((k) => { const ix = find(k); if (ix >= 0) col[k] = ix; });
      break;
    }
  }
  if (h < 0) throw new Error('مش لاقي أعمدة المبيعات — لازم Product ID و Order Product Quantity (و Delivered At و Breadfast Kitchen Name)');
  for (const k of ['date', 'kitchen'] as const) {
    if (col[k] === undefined) throw new Error(`عمود ناقص في ملف المبيعات: ${k === 'date' ? 'Delivered At' : 'Breadfast Kitchen Name'}`);
  }
  const out = { ...empty, bad: [] as ParsedSales['bad'] };
  const acc = new Map<string, SalesGroup & { map: Map<string, SalesRow> }>();
  for (let i = h + 1; i < table.length; i++) {
    const r = table[i] ?? [];
    if (r.every((c) => c === null || c === undefined || String(c).trim() === '')) continue;
    const rowNo = i + 1;
    const type = col.type === undefined ? '' : String(r[col.type] ?? '').trim().toLowerCase();
    if (type === 'modifier') { out.modifiers++; continue; }
    const kitchen = String(r[col.kitchen!] ?? '').trim().replace(/\s+/g, ' ');
    const date = parseSalesDate(r[col.date!]);
    const pid = cellText(r[col.pid!]);
    const qty = toNum(r[col.qty!]);
    if (!kitchen) { out.bad.push({ row: rowNo, reason: 'اسم المطبخ فاضي' }); continue; }
    if (!date) { out.bad.push({ row: rowNo, reason: `تاريخ غير مفهوم: ${String(r[col.date!] ?? '')}` }); continue; }
    if (!pid) { out.bad.push({ row: rowNo, reason: 'Product ID فاضي' }); continue; }
    if (qty === null) { out.bad.push({ row: rowNo, reason: `كمية غلط: ${String(r[col.qty!] ?? '')}` }); continue; }
    out.rows++;
    const key = `${normKitchen(kitchen)}|${date}`;
    let g = acc.get(key);
    if (!g) { g = { kitchenName: kitchen, kitchenKey: normKitchen(kitchen), date, rows: [], units: 0, map: new Map() }; acc.set(key, g); }
    const name = col.name === undefined ? '' : String(r[col.name] ?? '').trim();
    const ex = g.map.get(pid);
    if (ex) ex.qty = Math.round((ex.qty + qty) * 10000) / 10000; else g.map.set(pid, { pid, name, qty });
    g.units += qty;
  }
  const groups = [...acc.values()].map(({ map, ...g }) => ({ ...g, rows: [...map.values()], units: Math.round(g.units * 10000) / 10000 }))
    .sort((a, b) => a.kitchenKey.localeCompare(b.kitchenKey) || a.date.localeCompare(b.date));
  const dates = groups.map((g) => g.date).sort();
  const kmap = new Map<string, { name: string; key: string; days: number; units: number }>();
  for (const g of groups) {
    const k = kmap.get(g.kitchenKey) ?? { name: g.kitchenName, key: g.kitchenKey, days: 0, units: 0 };
    k.days++; k.units += g.units; kmap.set(g.kitchenKey, k);
  }
  return {
    ...out, groups,
    dates: dates.length ? { min: dates[0], max: dates[dates.length - 1] } : null,
    months: [...new Set(dates.map((d) => d.slice(0, 7)))],
    kitchens: [...kmap.values()],
  };
}

// UTF-16 (الـ BI بيصدّر كده) أو UTF-8
export function decodeText(buf: ArrayBuffer): string {
  const u = new Uint8Array(buf);
  if (u[0] === 0xff && u[1] === 0xfe) return new TextDecoder('utf-16le').decode(u.subarray(2));
  if (u[0] === 0xfe && u[1] === 0xff) return new TextDecoder('utf-16be').decode(u.subarray(2));
  if (u[0] === 0xef && u[1] === 0xbb && u[2] === 0xbf) return new TextDecoder('utf-8').decode(u.subarray(3));
  let zeros = 0; const n = Math.min(u.length, 400);
  for (let i = 1; i < n; i += 2) if (u[i] === 0) zeros++;
  if (n > 20 && zeros > n / 4) return new TextDecoder('utf-16le').decode(u);
  return new TextDecoder('utf-8').decode(u);
}

export async function readSalesFile(file: File): Promise<ParsedSales> {
  if (file.size > MAX_FILE_BYTES) throw new Error('الملف أكبر من 15 MB — قسّمه على أكتر من ملف');
  const name = file.name.toLowerCase();
  let table: unknown[][];
  if (name.endsWith('.xlsx')) table = (await readSheet(file)) as unknown[][];
  else if (name.endsWith('.csv') || name.endsWith('.txt') || name.endsWith('.tsv')) {
    const text = decodeText(await file.arrayBuffer());
    table = Papa.parse<string[]>(text, { skipEmptyLines: false, delimitersToGuess: ['\t', ',', ';', '|'] }).data;
  } else throw new Error('الملف لازم يكون .csv أو .xlsx');
  return parseSalesTable(table);
}

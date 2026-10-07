// تعريف أعمدة كل موديول + قراءة الأعمدة بالاسم (الترتيب مش مهم، والزيادة بتتجاهل)

export type ImportModule = 'products' | 'opening' | 'purchases' | 'wh_txn' | 'waste' | 'adjustments';
type Kind = 'text' | 'number' | 'date';

export type FieldSpec = { key: string; label: string; kind: Kind; aliases: string[] };

export type ModuleSpec = {
  key: ImportModule;
  label: string;
  page: string;            // صفحة الصلاحية
  needsKitchen: boolean;
  usesQty: boolean;
  fields: FieldSpec[];
  required: string[];      // مفاتيح لازم يكون ليها عمود
  template: string[];      // عناوين ملف القالب
};

const SYT = ['sytcode', 'syt', 'systemcode', 'كودالسيستم'];
const GENERIC = ['genericcode', 'generic'];

const TX_FIELDS: FieldSpec[] = [
  { key: 'date', label: 'Date', kind: 'date', aliases: ['date', 'postingdate', 'docdate', 'transactiondate', 'التاريخ', 'تاريخ'] },
  // الأولوية: Code ثم Syt ثم Generic
  { key: 'code', label: 'Code', kind: 'text', aliases: ['code', 'productcode', 'itemcode', ...SYT, ...GENERIC, 'item', 'الكود', 'كود'] },
  { key: 'qty', label: 'Qty', kind: 'number', aliases: ['qty', 'quantity', 'الكمية', 'كمية'] },
  { key: 'qty_pieces', label: 'Qty Pieces', kind: 'number', aliases: ['qtypieces', 'pieces', 'pcs', 'piecesqty', 'عددالقطع'] },
  { key: 'qty_base', label: 'Qty Base', kind: 'number', aliases: ['qtybase', 'baseqty', 'qtyinbaseunit', 'baseunitqty', 'الكميةبالوحدةالاساسية'] },
  { key: 'reason', label: 'Reason', kind: 'text', aliases: ['reason', 'السبب', 'سبب'] },
  { key: 'note', label: 'Note', kind: 'text', aliases: ['note', 'notes', 'remarks', 'ملاحظات'] },
];

const txSpec = (key: ImportModule, label: string, page: string, reason: 'none' | 'optional' | 'required' = 'none'): ModuleSpec => ({
  key, label, page, needsKitchen: true, usesQty: true,
  fields: TX_FIELDS,
  required: reason === 'required' ? ['date', 'code', 'reason'] : ['date', 'code'],
  template: reason === 'none' ? ['Date', 'Code', 'Qty', 'Note'] : ['Date', 'Code', 'Qty', 'Reason', 'Note'],
});

export const MODULES: Record<ImportModule, ModuleSpec> = {
  products: {
    key: 'products', label: 'Data Product', page: 'data_product', needsKitchen: false, usesQty: false,
    fields: [
      { key: 'syt_code', label: 'Syt Code', kind: 'text', aliases: SYT },
      { key: 'generic_code', label: 'Generic Code', kind: 'text', aliases: GENERIC },
      { key: 'name', label: 'Product Name', kind: 'text', aliases: ['productname', 'name', 'product', 'اسمالمنتج', 'المنتج'] },
      { key: 'uom_name', label: 'UoM', kind: 'text', aliases: ['uom', 'uomname', 'unitofmeasure', 'unit', 'baseunit', 'الوحدة'] },
      { key: 'category', label: 'Product/Financial Category', kind: 'text',
        aliases: ['productfinancialcategory', 'financialcategory', 'productcategory', 'category', 'cat', 'الفئة'] },
      { key: 'factor', label: 'Base Qty per Syt', kind: 'number',
        aliases: ['baseqtypersyt', 'baseqtyperpiece', 'qtypersyt', 'qtyperpiece', 'sytqty', 'conversion', 'conversionfactor', 'uomfactor', 'factor', 'كميةالكود'] },
      { key: 'cost', label: 'Cost', kind: 'number', aliases: ['cost', 'sytcost', 'unitcost', 'التكلفة'] },
      { key: 'cost_per_uom', label: 'Cost Pr UOM', kind: 'number', aliases: ['costpruom', 'costperuom', 'costuom', 'costperunit', 'costperkg', 'سعرالكيلو'] },
    ],
    required: ['syt_code'],
    template: ['Syt Code', 'Generic Code', 'Product Name', 'UoM', 'Product/Financial Category', 'Base Qty per Syt', 'Cost', 'Cost Pr UOM'],
  },
  opening: txSpec('opening', 'Opening Balance', 'opening_balance'),
  purchases: txSpec('purchases', 'Purchases', 'purchases'),
  wh_txn: txSpec('wh_txn', 'Warehouse Transactions', 'warehouse_transactions'),
  waste: txSpec('waste', 'Waste', 'waste', 'optional'),
  adjustments: txSpec('adjustments', 'Stock Adjustments', 'stock_adjustments', 'required'),
};

export const MODULE_ORDER: ImportModule[] = ['products', 'opening', 'purchases', 'wh_txn', 'waste', 'adjustments'];

// ---------- header + cell normalization ----------
export function normHeader(s: unknown): string {
  return String(s ?? '')
    .toLowerCase()
    .replace(/[\u064B-\u065F\u0670]/g, '')   // تشكيل
    .replace(/[أإآ]/g, 'ا')
    .replace(/[^a-z0-9\u0600-\u06FF]/g, '');
}

const ARABIC_DIGITS: Record<string, string> = {
  '٠': '0', '١': '1', '٢': '2', '٣': '3', '٤': '4', '٥': '5', '٦': '6', '٧': '7', '٨': '8', '٩': '9',
  '۰': '0', '۱': '1', '۲': '2', '۳': '3', '۴': '4', '۵': '5', '۶': '6', '۷': '7', '۸': '8', '۹': '9',
};

export function cellText(v: unknown): string {
  if (v === null || v === undefined) return '';
  if (v instanceof Date) return isoFromDate(v);
  if (typeof v === 'number') return Number.isInteger(v) ? String(v) : String(Number(v.toFixed(6)));
  return String(v).trim();
}

// read-excel-file بيرجّع Date عند منتصف الليل UTC لخلايا التاريخ
function isoFromDate(d: Date): string {
  if (Number.isNaN(d.getTime())) return '';
  return `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, '0')}-${String(d.getUTCDate()).padStart(2, '0')}`;
}

function validYMD(y: number, m: number, d: number): string | null {
  if (m < 1 || m > 12 || d < 1 || d > 31 || y < 1900 || y > 2200) return null;
  const dt = new Date(Date.UTC(y, m - 1, d));
  if (dt.getUTCFullYear() !== y || dt.getUTCMonth() !== m - 1 || dt.getUTCDate() !== d) return null;
  return `${y}-${String(m).padStart(2, '0')}-${String(d).padStart(2, '0')}`;
}

// بيرجّع yyyy-mm-dd لو قدر يفهم التاريخ، وإلا بيرجّع النص الأصلي (والـ DB بيعمل الخطأ برقم الصف)
export function normalizeDate(v: unknown): string {
  if (v instanceof Date) return isoFromDate(v);
  if (typeof v === 'number' && v > 20000 && v < 80000) {
    const ms = Date.UTC(1899, 11, 30) + Math.floor(v) * 86400000;
    return isoFromDate(new Date(ms));
  }
  let s = cellText(v).replace(/[٠-٩۰-۹]/g, (c) => ARABIC_DIGITS[c]);
  if (!s) return '';
  s = s.replace(/[T\s].*$/, '');           // شيل الوقت
  let m = /^(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})$/.exec(s);
  if (m) return validYMD(+m[1], +m[2], +m[3]) ?? cellText(v);
  m = /^(\d{1,2})[-/.](\d{1,2})[-/.](\d{4})$/.exec(s);   // يوم/شهر/سنة
  if (m) return validYMD(+m[3], +m[2], +m[1]) ?? cellText(v);
  if (/^\d{5}$/.test(s)) return normalizeDate(Number(s));
  return cellText(v);
}

export function normalizeNumber(v: unknown): string {
  if (typeof v === 'number') return Number.isFinite(v) ? String(Number(v.toFixed(6))) : '';
  let s = cellText(v).replace(/[٠-٩۰-۹]/g, (c) => ARABIC_DIGITS[c]).replace(/٫/g, '.').replace(/٬/g, ',').replace(/\s/g, '');
  if (!s) return '';
  if (/^[+-]?\d{1,3}(,\d{3})+(\.\d+)?$/.test(s)) s = s.replace(/,/g, '');      // 1,234.50
  else if (/^[+-]?\d+,\d+$/.test(s)) s = s.replace(',', '.');                   // 12,5
  return s;
}

// الكود ممكن يجي من Excel كرقم (1001) أو (1001.0)
export function normalizeCode(v: unknown): string {
  const s = cellText(v);
  return /^\d+\.0+$/.test(s) ? s.replace(/\.0+$/, '') : s;
}

// ---------- mapping ----------
export type MappedFile = {
  mapped: { field: string; header: string }[];
  ignored: string[];
  missing: string[];              // أعمدة مطلوبة ناقصة
  rows: { row_no: number; data: Record<string, string> }[];
};

export function mapRows(table: unknown[][], spec: ModuleSpec): MappedFile {
  const empty: MappedFile = { mapped: [], ignored: [], missing: [], rows: [] };
  if (!table.length) return { ...empty, missing: spec.required };

  // أول صف مش فاضي = العناوين
  let headerIdx = table.findIndex((r) => r.some((c) => cellText(c) !== ''));
  if (headerIdx < 0) return { ...empty, missing: spec.required };
  const headers = table[headerIdx].map((h) => cellText(h));

  // لكل عمود: أنهي field وبأولوية قد إيه
  type Col = { idx: number; field: FieldSpec; rank: number; header: string };
  const cols: Col[] = [];
  const ignored: string[] = [];
  headers.forEach((h, idx) => {
    const n = normHeader(h);
    if (!n) return;
    let hit: Col | null = null;
    for (const f of spec.fields) {
      const rank = f.aliases.indexOf(n);
      if (rank >= 0) { hit = { idx, field: f, rank, header: h }; break; }
    }
    if (hit) cols.push(hit); else ignored.push(h);
  });
  cols.sort((a, b) => a.rank - b.rank);

  const present = new Set(cols.map((c) => c.field.key));
  const missing = spec.required.filter((k) => !present.has(k));
  if (spec.usesQty && !['qty', 'qty_pieces', 'qty_base'].some((k) => present.has(k))) missing.push('qty');

  const rows: MappedFile['rows'] = [];
  for (let i = headerIdx + 1; i < table.length; i++) {
    const r = table[i];
    if (!r || r.every((c) => cellText(c) === '')) continue;
    const data: Record<string, string> = {};
    for (const c of cols) {
      if (data[c.field.key]) continue;                 // أول عمود ممتلئ حسب الأولوية
      const raw = r[c.idx];
      const val = c.field.kind === 'date' ? normalizeDate(raw)
        : c.field.kind === 'number' ? normalizeNumber(raw)
        : c.field.key === 'code' || c.field.key === 'syt_code' || c.field.key === 'generic_code' ? normalizeCode(raw)
        : cellText(raw);
      if (val !== '') data[c.field.key] = val;
    }
    rows.push({ row_no: i + 1, data });                // رقم الصف زي ما هو في الملف
  }

  const seen = new Set<string>();
  const mapped = cols.filter((c) => (seen.has(c.field.key) ? false : (seen.add(c.field.key), true)))
    .map((c) => ({ field: c.field.label, header: c.header }));
  return { mapped, ignored, missing, rows };
}

export const FIELD_LABEL: Record<string, string> = {
  date: 'Date', code: 'Code', qty: 'Qty / Qty Pieces / Qty Base', qty_pieces: 'Qty Pieces', qty_base: 'Qty Base',
  reason: 'Reason', note: 'Note', syt_code: 'Syt Code', name: 'Product Name',
};

// Low Stock: الحالة من الرصيد والحدود + قراءة شيت الحدود
import { mapRows, type ModuleSpec } from '@/lib/import/columns';

export type StockStatus = 'LOW' | 'AVG' | 'HIGH' | 'NOT_SET';

// الرصيد <= Low → LOW | >= High → HIGH | غير كده AVG | من غير حدود NOT_SET (نفس منطق الـ DB)
export function stockStatus(qty: number, low: number | null | undefined, high: number | null | undefined): StockStatus {
  if (low === null || low === undefined || high === null || high === undefined) return 'NOT_SET';
  if (qty <= low) return 'LOW';
  if (qty >= high) return 'HIGH';
  return 'AVG';
}

export const STATUS_LABEL: Record<StockStatus, string> = { LOW: 'Low stock', AVG: 'Avg stock', HIGH: 'High stock', NOT_SET: 'Not set' };
export const STATUS_BADGE: Record<StockStatus, string> = { LOW: 'err', AVG: 'warn', HIGH: 'ok', NOT_SET: '' };

const SPEC = {
  key: 'closing', label: 'Low Stock levels', page: 'low_stock', needsKitchen: true, usesQty: false,
  fields: [
    { key: 'code', label: 'Code', kind: 'text', aliases: ['code', 'productcode', 'itemcode', 'sytcode', 'syt', 'systemcode', 'genericcode', 'generic', 'item', 'الكود', 'كود'] },
    { key: 'low', label: 'Low Stock', kind: 'number', aliases: ['lowstock', 'low', 'lowqty', 'lowlevel', 'lowlimit', 'min', 'minqty', 'minstock', 'minimum', 'الحدالادنى', 'حدادنى', 'اقلكمية'] },
    { key: 'high', label: 'High Stock', kind: 'number', aliases: ['highstock', 'high', 'highqty', 'highlevel', 'highlimit', 'max', 'maxqty', 'maxstock', 'maximum', 'الحدالاقصى', 'حداقصى', 'اكبركمية'] },
  ],
  required: ['code', 'low', 'high'],
  template: ['Code', 'Product', 'Low Stock', 'High Stock'],
} as ModuleSpec;

export type LevelRow = { row: number; code: string; low: string; high: string };
export type LevelsFile = { rows: LevelRow[]; mapped: { field: string; header: string }[]; ignored: string[]; missing: string[] };

export function levelsFromTable(table: unknown[][]): LevelsFile {
  const m = mapRows(table, SPEC);
  return {
    rows: m.rows.map((r) => ({ row: r.row_no, code: r.data.code ?? '', low: r.data.low ?? '', high: r.data.high ?? '' })),
    mapped: m.mapped, ignored: m.ignored, missing: m.missing,
  };
}

export const MISSING_LABEL: Record<string, string> = { code: 'Code', low: 'Low Stock', high: 'High Stock' };

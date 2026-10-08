// تحويل الكميات: الرصيد والحركات بالوحدة الأساسية، والقطعة = كود السيستم = uom_factor وحدة أساسية
export type QtyMode = 'BASE' | 'PIECE';

export const round4 = (v: number) => Math.round(v * 10000) / 10000;
export const toBase = (qty: number, mode: QtyMode, factor: number) => (mode === 'PIECE' ? round4(qty * factor) : round4(qty));
export const toPieces = (base: number, factor: number) => (factor > 0 ? round4(base / factor) : base);
export const fmt = (v: unknown, max = 4) => Number(v ?? 0).toLocaleString('en-US', { maximumFractionDigits: max });

// أرشيف الصفحات: نفس شكل الـ Export (صف لكل صنف) لكل صفحات المستندات + تقارير Consumption / Warehouse Stock، في ZIP واحد
import type { SupabaseClient } from '@supabase/supabase-js';
import { fetchAllDocs } from '@/lib/doc-query';
import { buildDocTable, fetchLines } from '@/lib/doc-export';
import { xlsxBytes } from '@/lib/export';
import { makeZip } from '@/lib/zip';
import type { Kitchen } from '@/lib/types';

// جمل التأكيد (لازم تطابق اللي في الـ DB بالظبط)
export const purgePhrase = (fromMonth: string, toMonth: string, kitchenCode?: string | null) =>
  `PURGE ${fromMonth} → ${toMonth}${kitchenCode ? ` @ ${kitchenCode}` : ''}`;
export const clearPagePhrase = (page: string, kitchenCode?: string | null) => `CLEAR ${page} @ ${kitchenCode ?? 'ALL'}`;

export const ARCHIVE_PAGES = [
  { type: 'OPENING', title: 'Opening Balance' }, { type: 'PURCHASE', title: 'Purchases' }, { type: 'TRANSFER', title: 'Kitchens Transfer' },
  { type: 'WH_TXN', title: 'Warehouse Transactions' }, { type: 'WASTE', title: 'Waste' }, { type: 'CLOSING', title: 'Closing Stock Count' },
  { type: 'ADJUSTMENT', title: 'Stock Adjustments' },
] as const;

type RepRow = Record<string, unknown>;
const STOCK_COLS: [string, string][] = [['opening', 'Opening'], ['purchases', '+ Purchases'], ['transfer_in', '+ Transfer In'], ['transfer_out', '− Transfer Out'],
  ['warehouse_txn', '− Warehouse Txn'], ['waste', '− Waste'], ['adjustments', '± Adjustments'], ['closing_book', '= Stock'], ['in_transit', 'In transit'], ['return_pending', 'Return pending']];
const CONS_COLS: [string, string][] = [['opening', 'Opening'], ['purchases', '+ Purchases'], ['transfer_in', '+ Transfer In'], ['transfer_out', '− Transfer Out'],
  ['closing', '− Closing (count)'], ['waste', '− Waste'], ['consumption', '= Consumption']];

export function reportTable(kind: 'stock' | 'consumption', rows: RepRow[]) {
  const cols = kind === 'stock' ? STOCK_COLS : CONS_COLS;
  const valueKey = kind === 'stock' ? 'closing_book' : 'consumption';
  const n = (v: unknown) => Number(v ?? 0);
  return {
    headers: ['Syt Code', 'Generic Code', 'Product', 'Category', 'Base Qty per Syt', ...cols.map(([, l]) => l), 'Cost Pr UOM (current)', 'Value @ current cost'],
    rows: rows.map((r) => [r.syt_code as string, r.generic_code as string | null, r.product_name as string, r.category as string | null, n(r.uom_factor),
      ...cols.map(([k]) => n(r[k])), n(r.cost_per_uom), Math.round(n(r[valueKey]) * n(r.cost_per_uom) * 100) / 100]),
  };
}

async function fetchReport(sb: SupabaseClient, kind: 'stock' | 'consumption', kitchen: string, from: string, to: string): Promise<RepRow[]> {
  const all: RepRow[] = [];
  for (let f = 0; ; f += 1000) {
    const { data, error } = await sb.rpc(kind === 'stock' ? 'report_warehouse_stock' : 'report_consumption', { p_kitchen: kitchen, p_from: from, p_to: to }).range(f, f + 999);
    if (error) throw new Error(error.message);
    all.push(...((data ?? []) as RepRow[]));
    if (!data || data.length < 1000) break;
  }
  return all;
}

export async function buildArchive(sb: SupabaseClient, o: {
  kitchens: Kitchen[]; from: string; to: string; reports?: boolean; skipTransfers?: boolean; onProgress?: (msg: string) => void;
}): Promise<{ blob: Blob; name: string; summary: string[]; totalDocs: number }> {
  const enc = new TextEncoder();
  const files: { name: string; data: Uint8Array }[] = [];
  const summary: string[] = [];
  const nameOf = (id: string | null | undefined) => o.kitchens.find((k) => k.id === id)?.name ?? '—';
  let totalDocs = 0;

  for (const [i, pg] of ARCHIVE_PAGES.entries()) {
    if (o.skipTransfers && pg.type === 'TRANSFER') continue;   // مسح مطبخ واحد مبيمسحش التحويلات
    o.onProgress?.(`${pg.title}…`);
    const docs = [];
    for (const k of o.kitchens) docs.push(...await fetchAllDocs(sb, { type: pg.type, kitchenId: k.id, from: o.from, to: o.to, mode: 'own', reversals: true }));
    if (!docs.length) { summary.push(`${pg.title}: no documents`); continue; }
    const lines = await fetchLines(sb, docs.map((d) => d.id));
    const t = buildDocTable(pg.type, docs, lines, { kitchenName: '', kitchenNameOf: nameOf });
    files.push({ name: `${String(i + 1).padStart(2, '0')} ${pg.title}.xlsx`, data: await xlsxBytes(t.headers, t.rows) });
    summary.push(`${pg.title}: ${docs.length} documents, ${t.rows.length} rows`);
    totalDocs += docs.length;
  }

  if (o.reports !== false) {
    for (const k of o.kitchens) {
      for (const kind of ['consumption', 'stock'] as const) {
        const label = kind === 'stock' ? 'Warehouse Stock' : 'Consumption';
        o.onProgress?.(`${label} · ${k.name}…`);
        try {
          const rows = await fetchReport(sb, kind, k.id, o.from, o.to);
          if (!rows.length) { summary.push(`${label} · ${k.name}: no data`); continue; }
          const t = reportTable(kind, rows);
          files.push({ name: `${label} - ${k.name}.xlsx`, data: await xlsxBytes(t.headers, t.rows) });
          summary.push(`${label} · ${k.name}: ${rows.length} products`);
        } catch (e) { summary.push(`${label} · ${k.name}: skipped (${e instanceof Error ? e.message : String(e)})`); }
      }
    }
  }

  files.push({ name: 'README.txt', data: enc.encode(`KMS pages archive\nPeriod: ${o.from} → ${o.to}\nKitchens: ${o.kitchens.map((k) => k.name).join(', ')}\nCreated: ${new Date().toISOString()}\n\n${summary.join('\n')}\n`) });
  return { blob: makeZip(files), name: `kms-pages_${o.from}_${o.to}.zip`, summary, totalDocs };
}

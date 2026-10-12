// Export لصفحات المستندات: صف لكل صنف (مش ملخص للمستند) — Doc No / Date / Status / Lines / Note + تفاصيل المنتج
import type { SupabaseClient } from '@supabase/supabase-js';
import { downloadCsv, downloadXlsx, ymd } from '@/lib/export';

export type ExportDoc = {
  id: string; doc_no: string; doc_date: string; status: string; note: string | null; override_reason?: string | null;
  kitchen_id?: string; counterpart_kitchen_id?: string | null; reverses_document_id?: string | null;
  document_lines?: { count: number }[];
};

type TL = { sent_base: number; received_base: number | null; returned_base: number };
export type ExportLine = {
  document_id: string; line_no: number; qty_input: number; input_mode: string; qty_pieces: number; qty_base: number;
  reason: string | null; note: string | null; uom_factor_snapshot: number; unit_cost_snapshot: number | null;
  products: { syt_code: string; generic_code: string | null; name: string; category: string | null; uom_name: string | null } | null;
  transfer_lines: TL[] | TL | null;
};

export type Cell = string | number | boolean | null | undefined;
export type Table = { headers: string[]; rows: Cell[][] };

const num = (v: unknown): number | null => (v === null || v === undefined || v === '' ? null : Number(v));
const r4 = (v: number | null): number | null => (v === null ? null : Math.round(v * 10000) / 10000);
const tlOf = (l: ExportLine): TL | null => (Array.isArray(l.transfer_lines) ? l.transfer_lines[0] : l.transfer_lines) ?? null;

const QTY_LABEL: Record<string, string> = {
  CLOSING: 'Counted qty (base)', OPENING: 'Opening qty (base)', ADJUSTMENT: 'Qty (base, ± signed)',
};

/** بيبني الجدول: صف لكل سطر منتج. مستند من غير سطور بيطلع صف واحد فاضي عشان مايضيعش. */
export function buildDocTable(docType: string, docs: ExportDoc[], lines: ExportLine[], opts: { kitchenName: string; kitchenNameOf?: (id: string | null | undefined) => string }): Table {
  const transfer = docType === 'TRANSFER';
  const byDoc = new Map<string, ExportLine[]>();
  lines.forEach((l) => { const a = byDoc.get(l.document_id); if (a) a.push(l); else byDoc.set(l.document_id, [l]); });

  const head = transfer
    ? ['Doc No', 'Date', 'Status', 'From', 'To', 'Lines', 'Note']
    : ['Doc No', 'Date', 'Status', 'Kitchen', 'Lines', 'Note', 'Override reason'];
  const prod = ['Line #', 'Syt Code', 'Generic Code', 'Product', 'Category'];
  const tail = transfer
    ? ['Sent (base)', 'Sent (Syt pcs)', 'Received (base)', 'Received (Syt pcs)', 'Returned (base)', 'Pending return (base)', 'Unit cost (per base)', 'Sent value', 'Line note']
    : [QTY_LABEL[docType] ?? 'Qty (base)', 'Qty (Syt pcs)', 'Entered as', ...(docType === 'ADJUSTMENT' ? ['Effect'] : []), 'Unit cost (per base)', 'Line value', 'Reason', 'Line note'];

  const rows: Cell[][] = [];
  const nameOf = opts.kitchenNameOf ?? (() => opts.kitchenName);
  for (const d of docs) {
    const ls = (byDoc.get(d.id) ?? []).slice().sort((a, b) => a.line_no - b.line_no);
    const count = ls.length || d.document_lines?.[0]?.count || 0;
    const left: Cell[] = transfer
      ? [d.doc_no, d.doc_date, d.status, nameOf(d.kitchen_id), nameOf(d.counterpart_kitchen_id), count, d.note]
      : [d.doc_no, d.doc_date, d.status, opts.kitchenName, count, d.note, d.override_reason];
    if (!ls.length) { rows.push([...left, ...prod.map(() => null), ...tail.map(() => null)]); continue; }
    for (const l of ls) {
      const f = Number(l.uom_factor_snapshot) || 1;
      const base = r4(num(l.qty_base));
      const cost = num(l.unit_cost_snapshot);
      const p = l.products;
      const pcols: Cell[] = [l.line_no, p?.syt_code, p?.generic_code, p?.name, p?.category];
      if (transfer) {
        const t = tlOf(l);
        const sent = t ? Number(t.sent_base) : base ?? 0;
        const rec = t && t.received_base !== null ? Number(t.received_base) : null;
        const ret = t ? Number(t.returned_base) : 0;
        rows.push([...left, ...pcols,
          r4(sent), r4(sent / f), r4(rec), rec === null ? null : r4(rec / f), r4(ret),
          rec === null ? null : r4(sent - rec - ret), cost, cost === null ? null : r4(sent * cost), l.note]);
      } else {
        rows.push([...left, ...pcols,
          base, r4(num(l.qty_pieces)), `${Number(l.qty_input)} ${l.input_mode === 'PIECE' ? 'pcs' : 'base'}`,
          ...(docType === 'ADJUSTMENT' ? [(base ?? 0) < 0 ? 'Decrease' : 'Increase'] : []),
          cost, cost === null || base === null ? null : r4(base * cost), l.reason, l.note]);
      }
    }
  }
  return { headers: [...head, ...prod, ...tail], rows };
}

/** بيجيب سطور المستندات على دفعات (مفيش حد 1000 صف) */
export async function fetchLines(supabase: SupabaseClient, docIds: string[]): Promise<ExportLine[]> {
  const out: ExportLine[] = [];
  const SELECT = 'document_id,line_no,qty_input,input_mode,qty_pieces,qty_base,reason,note,uom_factor_snapshot,unit_cost_snapshot,'
    + 'products(syt_code,generic_code,name,category,uom_name),transfer_lines(sent_base,received_base,returned_base)';
  for (let i = 0; i < docIds.length; i += 60) {
    const chunk = docIds.slice(i, i + 60);
    for (let from = 0; ; from += 1000) {
      const { data, error } = await supabase.from('document_lines').select(SELECT).in('document_id', chunk)
        .order('document_id').order('line_no').range(from, from + 999);
      if (error) throw new Error(error.message);
      out.push(...((data ?? []) as unknown as ExportLine[]));
      if (!data || data.length < 1000) break;
    }
  }
  return out;
}

export async function exportDocuments(supabase: SupabaseClient, format: 'csv' | 'xlsx', docType: string, docs: ExportDoc[], opts: {
  kitchenName: string; kitchenNameOf?: (id: string | null | undefined) => string; fileBase?: string;
}) {
  const lines = await fetchLines(supabase, docs.map((d) => d.id));
  const t = buildDocTable(docType, docs, lines, opts);
  const base = `${opts.fileBase ?? docType.toLowerCase()}-${ymd(new Date())}`;
  if (format === 'csv') downloadCsv(`${base}.csv`, t.headers, t.rows);
  else await downloadXlsx(`${base}.xlsx`, t.headers, t.rows);
  return t.rows.length;
}

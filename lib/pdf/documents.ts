// PDF لمستند واحد (مشتريات / تحويل / جرد / هالك…) ولتقارير الصفحة (Stock / Consumption / Low Stock)
import type { SupabaseClient } from '@supabase/supabase-js';
import { buildPdf, pdfName, type PdfCell, type PdfSpec } from '@/lib/pdf/builder';
import { fmt } from '@/lib/qty';

export type PdfDoc = {
  id: string; doc_no: string; doc_type: string; doc_date: string; status: string; note: string | null;
  override_reason?: string | null; reverses_document_id?: string | null; kitchen_id: string; counterpart_kitchen_id?: string | null;
};
export type PdfResult = { blob: Blob; name: string };

const TITLE: Record<string, string> = {
  OPENING: 'Opening Balance', PURCHASE: 'Purchase', WH_TXN: 'Warehouse Transaction', SALES: 'Sales (BOM deduction)', WASTE: 'Waste',
  ADJUSTMENT: 'Stock Adjustment', CLOSING: 'Closing / Stock Count', TRANSFER: 'Kitchens Transfer',
};
const SIGNATURES: Record<string, string[]> = {
  TRANSFER: ['Sender', 'Receiver'], CLOSING: ['Counted by', 'Approved by'], PURCHASE: ['Received by', 'Approved by'],
};
const STATUS_LABEL: Record<string, string> = {
  PENDING_RECEIPT: 'In transit', RETURN_PENDING: 'Return pending', CLOSED_PARTIAL: 'Closed (partial)', COMPLETED: 'Completed',
};

type LineRow = {
  line_no: number; qty_input: number; input_mode: 'PIECE' | 'BASE'; qty_pieces: number; qty_base: number; reason: string | null; note: string | null;
  uom_factor_snapshot: number; unit_cost_snapshot: number | null;
  products: { syt_code: string; name: string } | null;
  transfer_lines: { sent_base: number; received_base: number | null; returned_base: number }[] | { sent_base: number; received_base: number | null; returned_base: number } | null;
};

export function documentSpec(doc: PdfDoc, lines: LineRow[], names: (id: string | null | undefined) => string): PdfSpec {
  const transfer = doc.doc_type === 'TRANSFER';
  const meta: [string, string][] = transfer
    ? [['From', names(doc.kitchen_id)], ['To', names(doc.counterpart_kitchen_id)]]
    : [['Kitchen', names(doc.kitchen_id)]];
  meta.push(['Date', doc.doc_date], ['Status', STATUS_LABEL[doc.status] ?? doc.status]);
  if (doc.reverses_document_id) meta.push(['Type', 'Reversal document']);
  if (doc.override_reason) meta.push(['Period override', doc.override_reason]);
  if (doc.note) meta.push(['Note', doc.note]);

  const tl = (l: LineRow) => (Array.isArray(l.transfer_lines) ? l.transfer_lines[0] : l.transfer_lines) ?? null;
  let cols: PdfSpec['sections'][0]['cols']; let rows: PdfCell[][]; let foot: PdfCell[] | undefined;
  if (transfer) {
    cols = [{ head: '#', w: 3 }, { head: 'Syt Code', w: 10 }, { head: 'Product', w: 26 }, { head: 'Sent', w: 8, align: 'right' }, { head: 'Received', w: 8, align: 'right' },
      { head: 'Returned', w: 8, align: 'right' }, { head: 'Pending return', w: 9, align: 'right' }, { head: 'Note', w: 14 }];
    rows = lines.map((l) => {
      const t = tl(l); const sent = Number(t?.sent_base ?? l.qty_base);
      const recv = t?.received_base == null ? null : Number(t.received_base); const ret = Number(t?.returned_base ?? 0);
      return [l.line_no, l.products?.syt_code, l.products?.name, fmt(sent), recv === null ? '' : fmt(recv), recv === null ? '' : fmt(ret), recv === null ? '' : fmt(sent - recv - ret), l.note ?? ''];
    });
    foot = ['', '', 'Total', fmt(lines.reduce((s, l) => s + Number(tl(l)?.sent_base ?? l.qty_base), 0)), '', '', '', ''];
  } else {
    cols = [{ head: '#', w: 3 }, { head: 'Syt Code', w: 10 }, { head: 'Product', w: 25 }, { head: 'Qty (base)', w: 8, align: 'right' }, { head: 'Syt pcs', w: 7, align: 'right' },
      { head: 'Unit cost', w: 7, align: 'right' }, { head: 'Value', w: 8, align: 'right' }, { head: 'Reason / Note', w: 15 }];
    let total = 0;
    rows = lines.map((l) => {
      const q = Number(l.qty_base); const c = l.unit_cost_snapshot == null ? null : Number(l.unit_cost_snapshot);
      const v = c === null ? null : q * c; if (v !== null) total += v;
      const f = Number(l.uom_factor_snapshot);
      return [l.line_no, l.products?.syt_code, l.products?.name, fmt(q), f !== 1 ? fmt(l.qty_pieces) : '', c === null ? '' : fmt(c, 4), v === null ? '' : fmt(v, 2),
        [l.reason, l.note].filter(Boolean).join(' — ')];
    });
    foot = ['', '', 'Total', fmt(lines.reduce((s, l) => s + Number(l.qty_base), 0)), '', '', fmt(total, 2), ''];
  }
  return {
    title: `${TITLE[doc.doc_type] ?? doc.doc_type} · ${doc.doc_no}`, subtitle: `${lines.length} line${lines.length === 1 ? '' : 's'}`, meta,
    sections: [{ title: 'Lines', cols, rows, foot }],
    signatures: SIGNATURES[doc.doc_type] ?? ['Prepared by', 'Approved by'],
    note: doc.doc_type === 'CLOSING' ? 'This count becomes the opening balance of the following period. / الجرد ده هو رصيد أول المدة للفترة اللي بعده.' : undefined,
  };
}

export async function documentPdf(supabase: SupabaseClient, doc: PdfDoc, names: (id: string | null | undefined) => string): Promise<PdfResult> {
  const { data, error } = await supabase.from('document_lines')
    .select('line_no,qty_input,input_mode,qty_pieces,qty_base,reason,note,uom_factor_snapshot,unit_cost_snapshot,products(syt_code,name),transfer_lines(sent_base,received_base,returned_base)')
    .eq('document_id', doc.id).order('line_no');
  if (error) throw new Error(error.message);
  const blob = await buildPdf(documentSpec(doc, (data ?? []) as unknown as LineRow[], names));
  return { blob, name: pdfName(doc.doc_no) };
}

// تقرير جدولي (Stock / Consumption / Low Stock): الأعمدة والصفوف جاهزة من الصفحة
export async function reportPdf(o: { title: string; subtitle: string; meta?: [string, string][]; cols: { head: string; w: number; align?: 'left' | 'right' | 'center' }[]; rows: PdfCell[][]; foot?: PdfCell[]; note?: string; fileBase: string }): Promise<PdfResult> {
  const blob = await buildPdf({ title: o.title, subtitle: o.subtitle, meta: o.meta, landscape: true, sections: [{ cols: o.cols, rows: o.rows, foot: o.foot }], note: o.note });
  return { blob, name: pdfName(o.fileBase) };
}

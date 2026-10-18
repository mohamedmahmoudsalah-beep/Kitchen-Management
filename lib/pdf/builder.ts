// بناء PDF (جداول بالإنجليزي والعربي) — jsPDF + autoTable، بيتحمّلوا ديناميك وقت الضغط بس.
import { isRtlText, shapeText, wrapLogical } from '@/lib/pdf/shape';

export type PdfCol = { head: string; w: number; align?: 'left' | 'right' | 'center' };
export type PdfCell = string | number | null | undefined;
export type PdfSection = { title?: string; cols: PdfCol[]; rows: PdfCell[][]; foot?: PdfCell[] };
export type PdfSpec = {
  title: string; subtitle?: string; meta?: [string, string][]; sections: PdfSection[];
  landscape?: boolean; signatures?: string[]; note?: string;
};

// jsPDF بيعمل Arabic shaping + Bidi لوحده، وده بيبوّظ النص اللي إحنا شكّلناه (بيتعالج مرتين). بنشيل الـ hooks دي ونتحكم إحنا في الشكل.
type JsPdfStatic = { API: { events: [string, unknown][]; processArabic?: unknown } };
function disableBuiltInArabic(jsPDF: JsPdfStatic) {
  const ev = jsPDF.API.events;
  for (let i = ev.length - 1; i >= 0; i--) {
    const [name, fn] = ev[i];
    const arabic = name === 'preProcessText' && fn === jsPDF.API.processArabic;
    const bidi = name === 'postProcessText' && typeof fn === 'function' && String(fn).includes('isInputVisual');
    if (arabic || bidi) ev.splice(i, 1);
  }
}

const BRAND: [number, number, number] = [167, 38, 141];
const NAVY: [number, number, number] = [15, 21, 54];
const MUTED: [number, number, number] = [94, 88, 115];

export async function buildPdf(spec: PdfSpec): Promise<Blob> {
  const [{ jsPDF }, autoTableMod, fonts] = await Promise.all([import('jspdf'), import('jspdf-autotable'), import('@/lib/pdf/cairo-fonts')]);
  const autoTable = autoTableMod.default;
  disableBuiltInArabic(jsPDF as unknown as JsPdfStatic);
  const doc = new jsPDF({ orientation: spec.landscape ? 'landscape' : 'portrait', unit: 'mm', format: 'a4' });
  doc.addFileToVFS('Cairo-Regular.ttf', fonts.CAIRO_REGULAR); doc.addFont('Cairo-Regular.ttf', 'Cairo', 'normal');
  doc.addFileToVFS('Cairo-Bold.ttf', fonts.CAIRO_BOLD); doc.addFont('Cairo-Bold.ttf', 'Cairo', 'bold');
  doc.setProperties({ title: spec.title, creator: 'Breadfast KMS' });

  const W = doc.internal.pageSize.getWidth(); const H = doc.internal.pageSize.getHeight();
  const M = 12; const avail = W - 2 * M;
  const generated = new Date().toISOString().slice(0, 16).replace('T', ' ');

  // نص بالترتيب البصري، محاذي حسب اتجاهه
  const text = (s: string, x: number, y: number, opts: { size?: number; bold?: boolean; color?: [number, number, number]; right?: boolean } = {}) => {
    doc.setFont('Cairo', opts.bold ? 'bold' : 'normal'); doc.setFontSize(opts.size ?? 9); doc.setTextColor(...(opts.color ?? NAVY));
    const shaped = shapeText(s);
    doc.text(shaped, opts.right ? x - doc.getTextWidth(shaped) : x, y);
    return doc.getTextWidth(shaped);
  };

  // الهيدر
  doc.setFillColor(...BRAND); doc.rect(0, 0, W, 12, 'F');
  text('Breadfast', M, 8, { size: 12, bold: true, color: [255, 255, 255] });
  text('Kitchen Management System', M + 26, 8, { size: 8.5, color: [255, 220, 245] });
  text(`Generated ${generated}`, W - M, 8, { size: 8, color: [255, 255, 255], right: true });

  let y = 22;
  text(spec.title, M, y, { size: 16, bold: true });
  y += 6;
  if (spec.subtitle) { text(spec.subtitle, M, y, { size: 9.5, color: MUTED }); y += 5; }
  if (spec.meta?.length) {
    y += 2;
    const colW = avail / 2;
    spec.meta.forEach(([k, v], i) => {
      const cx = M + (i % 2) * colW; const cy = y + Math.floor(i / 2) * 5.2;
      const kw = text(`${k}:`, cx, cy, { size: 8.5, bold: true, color: MUTED });
      const lines = wrapLogical(v || '-', colW - kw - 6, (s) => { doc.setFont('Cairo', 'normal'); doc.setFontSize(8.5); return doc.getTextWidth(s); });
      text(lines[0] + (lines.length > 1 ? ' …' : ''), cx + kw + 2, cy, { size: 8.5 });
    });
    y += Math.ceil(spec.meta.length / 2) * 5.2 + 2;
  }
  y += 2;

  for (const sec of spec.sections) {
    if (sec.title) { text(sec.title, M, y + 4, { size: 10.5, bold: true }); y += 7; }
    const totalW = sec.cols.reduce((s, c) => s + c.w, 0);
    const widths = sec.cols.map((c) => (c.w / totalW) * avail);
    const pad = 1.6;
    doc.setFont('Cairo', 'normal'); doc.setFontSize(8);
    const measure = (s: string) => doc.getTextWidth(s);
    const cell = (v: PdfCell, i: number) => {
      const s = v === null || v === undefined ? '' : String(v);
      const lines = wrapLogical(s, widths[i] - 2 * pad - 0.5, measure).map(shapeText);
      const align = sec.cols[i].align ?? (isRtlText(s) ? 'right' : 'left');
      return { content: lines.join('\n'), styles: { halign: align } };
    };
    autoTable(doc, {
      startY: y, margin: { left: M, right: M, top: 18, bottom: 14 }, theme: 'grid',
      tableWidth: avail,
      head: [sec.cols.map((c) => ({ content: shapeText(c.head), styles: { halign: c.align ?? 'left' } }))],
      body: sec.rows.map((r) => sec.cols.map((_, i) => cell(r[i], i))),
      foot: sec.foot ? [sec.cols.map((_, i) => cell(sec.foot![i], i))] : undefined,
      showFoot: 'lastPage',
      styles: { font: 'Cairo', fontSize: 8, cellPadding: pad, lineColor: [210, 214, 232], lineWidth: 0.1, textColor: NAVY, overflow: 'visible', valign: 'middle' },
      headStyles: { fillColor: NAVY, textColor: [255, 255, 255], fontStyle: 'bold' },
      footStyles: { fillColor: [244, 230, 241], textColor: NAVY, fontStyle: 'bold' },
      alternateRowStyles: { fillColor: [249, 250, 253] },
      columnStyles: Object.fromEntries(widths.map((w, i) => [i, { cellWidth: w }])),
      didDrawPage: (data) => {
        // الصفحات التانية: شريط رفيع فوق
        if (doc.getCurrentPageInfo().pageNumber > 1) { doc.setFillColor(...BRAND); doc.rect(0, 0, W, 6, 'F'); }
        void data;
      },
    });
    y = (doc as unknown as { lastAutoTable: { finalY: number } }).lastAutoTable.finalY + 6;
  }

  if (spec.note) {
    const lines = wrapLogical(spec.note, avail, (s) => { doc.setFont('Cairo', 'normal'); doc.setFontSize(8.5); return doc.getTextWidth(s); });
    if (y + lines.length * 4.5 > H - 16) { doc.addPage(); y = 20; }
    lines.forEach((l, i) => text(l, M, y + i * 4.5, { size: 8.5, color: MUTED }));
    y += lines.length * 4.5 + 4;
  }
  if (spec.signatures?.length) {
    if (y + 24 > H - 16) { doc.addPage(); y = 24; }
    y += 14;
    const w = avail / spec.signatures.length;
    spec.signatures.forEach((label, i) => {
      const x = M + i * w + 4;
      doc.setDrawColor(...MUTED); doc.setLineWidth(0.2); doc.line(x, y, x + w - 14, y);
      text(label, x, y + 4.5, { size: 8.5, color: MUTED });
    });
  }

  // أرقام الصفحات
  const pages = doc.getNumberOfPages();
  for (let p = 1; p <= pages; p++) {
    doc.setPage(p);
    text(`Page ${p} of ${pages}`, W / 2 - 8, H - 7, { size: 8, color: MUTED });
    text('Breadfast · Kitchen Management System', M, H - 7, { size: 7.5, color: MUTED });
  }
  return doc.output('blob');
}

export const pdfName = (...parts: (string | null | undefined)[]) =>
  `${parts.filter(Boolean).join('_').replace(/[^\w.\-@]+/g, '_')}.pdf`;

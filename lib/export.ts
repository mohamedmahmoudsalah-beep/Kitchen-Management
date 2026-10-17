// تصدير CSV (UTF-8 + BOM عشان Excel يقرا العربي) و XLSX

// CSV injection: نص بيبدأ بـ = + - @ (أو tab/CR) Excel بيعتبره معادلة. بنحط ' قبله (الأرقام الحقيقية زي -5 بتفضل زي ما هي)
const NUMERIC = /^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$/;
export const neutralizeFormula = (s: string) => (/^[=+\-@\t\r]/.test(s) && !NUMERIC.test(s) ? `'${s}` : s);

export function toCsv(headers: string[], rows: (string | number | boolean | null | undefined)[][]): string {
  const esc = (v: unknown) => {
    const s = v === null || v === undefined ? '' : typeof v === 'string' ? neutralizeFormula(v) : String(v);
    return /[",\r\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
  };
  return '\uFEFF' + [headers, ...rows].map((r) => r.map(esc).join(',')).join('\r\n');
}

export function saveBlob(blob: Blob, fileName: string) {
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url; a.download = fileName; document.body.appendChild(a); a.click(); a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

export function downloadCsv(fileName: string, headers: string[], rows: (string | number | boolean | null | undefined)[][]) {
  saveBlob(new Blob([toCsv(headers, rows)], { type: 'text/csv;charset=utf-8' }), fileName);
}

export async function downloadXlsx(fileName: string, headers: string[], rows: (string | number | boolean | null | undefined)[][]) {
  const { default: writeExcelFile } = await import('write-excel-file/browser');
  const data = [
    headers.map((h) => ({ value: h, fontWeight: 'bold' as const })),
    ...rows.map((r) => r.map((v) => (v === null || v === undefined ? null : typeof v === 'boolean' ? String(v) : v))),
  ];
  const blob = await writeExcelFile(data as never).toBlob();
  saveBlob(blob, fileName);
}

export async function xlsxBytes(headers: string[], rows: (string | number | boolean | null | undefined)[][]): Promise<Uint8Array> {
  const { default: writeExcelFile } = await import('write-excel-file/browser');
  const data = [
    headers.map((h) => ({ value: h, fontWeight: 'bold' as const })),
    ...rows.map((r) => r.map((v) => (v === null || v === undefined ? null : typeof v === 'boolean' ? String(v) : v))),
  ];
  const blob = await writeExcelFile(data as never).toBlob();
  return new Uint8Array(await blob.arrayBuffer());
}

export const ymd = (d: Date) =>
  `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;

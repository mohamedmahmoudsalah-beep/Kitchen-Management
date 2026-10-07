// تصدير CSV (UTF-8 + BOM عشان Excel يقرا العربي) و XLSX

export function toCsv(headers: string[], rows: (string | number | boolean | null | undefined)[][]): string {
  const esc = (v: unknown) => {
    const s = v === null || v === undefined ? '' : String(v);
    return /[",\r\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
  };
  return '\uFEFF' + [headers, ...rows].map((r) => r.map(esc).join(',')).join('\r\n');
}

function save(blob: Blob, fileName: string) {
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url; a.download = fileName; document.body.appendChild(a); a.click(); a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

export function downloadCsv(fileName: string, headers: string[], rows: (string | number | boolean | null | undefined)[][]) {
  save(new Blob([toCsv(headers, rows)], { type: 'text/csv;charset=utf-8' }), fileName);
}

export async function downloadXlsx(fileName: string, headers: string[], rows: (string | number | boolean | null | undefined)[][]) {
  const { default: writeExcelFile } = await import('write-excel-file/browser');
  const data = [
    headers.map((h) => ({ value: h, fontWeight: 'bold' as const })),
    ...rows.map((r) => r.map((v) => (v === null || v === undefined ? null : typeof v === 'boolean' ? String(v) : v))),
  ];
  const blob = await writeExcelFile(data as never).toBlob();
  save(blob, fileName);
}

export const ymd = (d: Date) =>
  `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;

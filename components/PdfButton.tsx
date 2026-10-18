'use client';
import { useState } from 'react';
import { FileDown, Loader2 } from 'lucide-react';
import { saveBlob } from '@/lib/export';
import type { PdfResult } from '@/lib/pdf/documents';

// تحميل PDF: بيبني الملف في المتصفح (المكتبة والخط بيتحمّلوا وقت الضغط بس)
export default function PdfButton({ build, label, title = 'Download PDF', disabled = false, small = false }: {
  build: () => Promise<PdfResult>; label?: string; title?: string; disabled?: boolean; small?: boolean;
}) {
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  async function run() {
    setBusy(true); setErr(null);
    try { const r = await build(); saveBlob(r.blob, r.name); }
    catch (e) { setErr(e instanceof Error ? e.message : String(e)); }
    setBusy(false);
  }
  const icon = busy ? <Loader2 size={small ? 14 : 14} className="spin" /> : <FileDown size={small ? 15 : 14} />;
  if (label) {
    return (
      <>
        <button className="btn secondary" disabled={busy || disabled} onClick={run} title={title}>{icon} {busy ? 'Building…' : label}</button>
        {err && <span className="badge err" title={err}>PDF failed</span>}
      </>
    );
  }
  return (
    <button type="button" className="icon-btn pdf-btn" disabled={busy || disabled} onClick={run} title={err ? `فشل: ${err}` : title} aria-label={title}
      style={err ? { color: 'var(--err)' } : undefined}>{icon}</button>
  );
}

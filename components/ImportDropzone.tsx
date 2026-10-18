'use client';
import { useRef, useState } from 'react';
import { useRouter } from 'next/navigation';
import { UploadCloud } from 'lucide-react';
import { isSheetFile, setPendingImportFile } from '@/lib/import/handoff';

// زرار الاستيراد الكبير: اسحب الشيت عليه أو دوس عليه واختار الملف، وبيروح لصفحة الـ Import والملف متحمّل
export default function ImportDropzone({ module }: { module: string }) {
  const router = useRouter();
  const input = useRef<HTMLInputElement>(null);
  const [over, setOver] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  function take(f: File | undefined | null) {
    setOver(false);
    if (!f) return;
    if (!isSheetFile(f)) { setErr('الملف لازم يكون Excel (.xlsx) أو CSV'); return; }
    setErr(null);
    setPendingImportFile(f);
    router.push(`/import-export?module=${module}`);
  }

  return (
    <div className={`dropzone ${over ? 'over' : ''}`} role="button" tabIndex={0} aria-label="Import sheet: drop a file or click to choose"
      title="اسحب الشيت هنا، أو دوس واختار الملف"
      onClick={() => input.current?.click()}
      onKeyDown={(e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); input.current?.click(); } }}
      onDragOver={(e) => { e.preventDefault(); setOver(true); }}
      onDragLeave={() => setOver(false)}
      onDrop={(e) => { e.preventDefault(); take(e.dataTransfer.files?.[0]); }}>
      <span className="dz-icon"><UploadCloud size={24} /></span>
      <span className="dz-text">
        <b>{over ? 'Drop to import' : 'Import sheet'}</b>
        <small>{err ?? 'Drop the file here or click'}</small>
      </span>
      <input ref={input} type="file" accept=".xlsx,.csv,.txt" hidden onChange={(e) => { take(e.target.files?.[0]); e.target.value = ''; }} />
    </div>
  );
}

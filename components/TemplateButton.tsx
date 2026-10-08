'use client';
import { useMemo, useState } from 'react';
import { FileSpreadsheet } from 'lucide-react';
import { createClient } from '@/lib/supabase/client';
import { useScope } from '@/components/ScopeProvider';
import { downloadTemplate } from '@/lib/import/templates';
import type { ImportModule } from '@/lib/import/columns';

// زرار تحميل شيت Excel مثال للتمبلت — موجود في كل صفحة ليها Import
export default function TemplateButton({ module, small = false }: { module: ImportModule; small?: boolean }) {
  const supabase = useMemo(() => createClient(), []);
  const { kitchens, kitchen } = useScope();
  const [busy, setBusy] = useState(false);
  return (
    <button className={`btn secondary ${small ? 'small' : ''}`} disabled={busy} title="تحميل ملف Excel مثال للتمبلت"
      onClick={async () => { setBusy(true); try { await downloadTemplate(supabase, module, kitchens.map((k) => k.name), kitchen?.name); } finally { setBusy(false); } }}>
      <FileSpreadsheet size={14} /> Excel template
    </button>
  );
}

'use client';
import { useMemo, useState } from 'react';
import { DatabaseBackup } from 'lucide-react';
import { createClient } from '@/lib/supabase/client';
import { BACKUP_TABLES, runBackup } from '@/lib/backup';

export default function BackupPanel() {
  const supabase = useMemo(() => createClient(), []);
  const [withHeavy, setWithHeavy] = useState(true);
  const [busy, setBusy] = useState(false);
  const [progress, setProgress] = useState('');
  const [msg, setMsg] = useState<{ kind: 'ok' | 'err'; text: string } | null>(null);

  async function go() {
    setBusy(true); setMsg(null); setProgress('Starting…');
    try {
      const tables = BACKUP_TABLES.filter((t) => withHeavy || !t.heavy);
      const { blob, name, counts } = await runBackup(supabase, tables, (t, n) => setProgress(`${t}: ${n.toLocaleString()} rows…`));
      const url = URL.createObjectURL(blob);
      const a = document.createElement('a'); a.href = url; a.download = name; document.body.appendChild(a); a.click(); a.remove();
      setTimeout(() => URL.revokeObjectURL(url), 2000);
      const total = Object.values(counts).reduce((x, y) => x + y, 0);
      setMsg({ kind: 'ok', text: `تم تنزيل ${name} — ${tables.length} جدول، ${total.toLocaleString()} صف` });
    } catch (e) { setMsg({ kind: 'err', text: e instanceof Error ? e.message : String(e) }); }
    setBusy(false); setProgress('');
  }

  return (
    <div className="panel" style={{ marginTop: 16 }} dir="auto">
      <h2 style={{ display: 'flex', gap: 8, alignItems: 'center' }}><DatabaseBackup size={18} /> Backup (Admin)</h2>
      <p className="muted">بينزّل كل جداول النظام كملفات CSV جوه ZIP واحد. النسخة المجانية من Supabase مفيهاش Backups تلقائية، فاعمل ده بشكل دوري (أسبوعيًا مثلًا) واحتفظ بالملف بره النظام.</p>
      <label className="checks"><span><input type="checkbox" checked={withHeavy} onChange={(e) => setWithHeavy(e.target.checked)} /> شمل Stock Ledger وAudit Log (الأكبر حجمًا — قد ياخد وقت مع الداتا الكبيرة)</span></label>
      <div className="form-row" style={{ marginTop: 10 }}>
        <button className="btn" disabled={busy} onClick={go}>{busy ? 'Backing up…' : 'Download backup (ZIP)'}</button>
        {busy && <span className="muted">{progress}</span>}
      </div>
      {msg && <div className={`alert ${msg.kind}`} style={{ marginTop: 10 }}>{msg.text}</div>}
    </div>
  );
}

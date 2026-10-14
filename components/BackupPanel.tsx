'use client';
import { useMemo, useState } from 'react';
import { DatabaseBackup } from 'lucide-react';
import { createClient } from '@/lib/supabase/client';
import { BACKUP_TABLES, runBackup } from '@/lib/backup';
import { useScope } from '@/components/ScopeProvider';
import { buildArchive } from '@/lib/archive';
import ArchivePurgePanel from '@/components/ArchivePurgePanel';
import PageDataPanel from '@/components/PageDataPanel';
import ResetPanel from '@/components/ResetPanel';
import { saveBlob, ymd } from '@/lib/export';

function PagesBackup() {
  const supabase = useMemo(() => createClient(), []);
  const { kitchens } = useScope();
  const [from, setFrom] = useState(() => { const d = new Date(); return ymd(new Date(d.getFullYear(), d.getMonth(), 1)); });
  const [to, setTo] = useState(ymd(new Date()));
  const [pick, setPick] = useState<string>('ALL');
  const [reports, setReports] = useState(true);
  const [busy, setBusy] = useState(false);
  const [progress, setProgress] = useState('');
  const [msg, setMsg] = useState<{ kind: 'ok' | 'err'; text: string } | null>(null);

  async function go() {
    setBusy(true); setMsg(null); setProgress('Starting…');
    try {
      const ks = pick === 'ALL' ? kitchens : kitchens.filter((k) => k.id === pick);
      const a = await buildArchive(supabase, { kitchens: ks, from, to, reports, onProgress: setProgress });
      saveBlob(a.blob, a.name);
      setMsg({ kind: 'ok', text: `تم تنزيل ${a.name} — ${a.totalDocs} مستند` });
    } catch (e) { setMsg({ kind: 'err', text: e instanceof Error ? e.message : String(e) }); }
    setBusy(false); setProgress('');
  }
  return (
    <div className="panel" style={{ marginTop: 16 }} dir="auto">
      <h2 style={{ display: 'flex', gap: 8, alignItems: 'center' }}><DatabaseBackup size={18} /> Backup الصفحات بالتاريخ (Admin)</h2>
      <p className="muted">اختار فترة ومطبخ (أو كل المطابخ) وهينزّل نفس ملفات الـ Export بتاعة الصفحات (صف لكل صنف): Opening, Purchases, Transfers, Warehouse Txn, Waste, Closing, Adjustments، ومعاهم تقارير Consumption وWarehouse Stock لكل مطبخ — كلهم في ZIP واحد.</p>
      <div className="form-row">
        <label className="field"><span>From</span><input type="date" value={from} max={to} onChange={(e) => setFrom(e.target.value)} /></label>
        <label className="field"><span>To</span><input type="date" value={to} min={from} onChange={(e) => setTo(e.target.value)} /></label>
        <label className="field"><span>Kitchen</span>
          <select value={pick} onChange={(e) => setPick(e.target.value)}>
            <option value="ALL">All kitchens</option>
            {kitchens.map((k) => <option key={k.id} value={k.id}>{k.name}</option>)}
          </select></label>
        <label className="checks"><span><input type="checkbox" checked={reports} onChange={(e) => setReports(e.target.checked)} /> شمل تقارير Consumption وWarehouse Stock</span></label>
      </div>
      <div className="form-row" style={{ marginTop: 10 }}>
        <button className="btn" disabled={busy || !from || !to} onClick={go}>{busy ? 'Preparing…' : 'Download pages (ZIP)'}</button>
        {busy && <span className="muted">{progress}</span>}
      </div>
      {msg && <div className={`alert ${msg.kind}`} style={{ marginTop: 10 }}>{msg.text}</div>}
    </div>
  );
}

function RawBackup() {
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
    <details className="panel" style={{ marginTop: 16, padding: '10px 14px' }} dir="auto">
      <summary style={{ cursor: 'pointer', fontWeight: 600 }}>نسخة احتياطية خام لكل جداول الداتا بيز (للطوارئ فقط)</summary>
      <p className="muted">بينزّل كل جداول النظام كملفات CSV خام جوه ZIP واحد (مش بشكل الصفحات). النسخة المجانية من Supabase مفيهاش Backups تلقائية.</p>
      <label className="checks"><span><input type="checkbox" checked={withHeavy} onChange={(e) => setWithHeavy(e.target.checked)} /> شمل Stock Ledger وAudit Log (الأكبر حجمًا — قد ياخد وقت مع الداتا الكبيرة)</span></label>
      <div className="form-row" style={{ marginTop: 10 }}>
        <button className="btn" disabled={busy} onClick={go}>{busy ? 'Backing up…' : 'Download backup (ZIP)'}</button>
        {busy && <span className="muted">{progress}</span>}
      </div>
      {msg && <div className={`alert ${msg.kind}`} style={{ marginTop: 10 }}>{msg.text}</div>}
    </details>
  );
}

export default function BackupPanel() {
  return <><PagesBackup /><ArchivePurgePanel /><PageDataPanel /><RawBackup /><ResetPanel /></>;
}

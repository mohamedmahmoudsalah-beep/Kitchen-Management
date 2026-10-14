'use client';
import { useMemo, useState } from 'react';
import { AlertTriangle } from 'lucide-react';
import { createClient } from '@/lib/supabase/client';

// منطقة الخطر (Admin): مسح كل البيانات اللي اتضافت والـ Logs، والنظام يبقى كأنه جديد.
export default function ResetPanel() {
  const supabase = useMemo(() => createClient(), []);
  const [pw, setPw] = useState('');
  const [sure, setSure] = useState(false);
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<{ kind: 'ok' | 'err'; text: string } | null>(null);

  async function go() {
    setBusy(true); setMsg(null);
    const { data, error } = await supabase.rpc('reset_all_data', { p_password: pw });
    if (error) setMsg({ kind: 'err', text: error.message });
    else {
      const r = data as Record<string, number>;
      setMsg({ kind: 'ok', text: `تم المسح: ${r.documents} مستند، ${r.stock_ledger} حركة، ${r.products} منتج، ${r.audit_log} سجل Audit. النظام جديد. اعمل Refresh للصفحة.` });
      setPw(''); setSure(false);
    }
    setBusy(false);
  }

  return (
    <div className="panel" style={{ marginTop: 16, borderColor: '#f3c3ca' }} dir="auto">
      <h2 style={{ display: 'flex', gap: 8, alignItems: 'center', color: 'var(--err)' }}><AlertTriangle size={18} /> منطقة الخطر — مسح كل البيانات (Admin)</h2>
      <p className="muted">
        بيمسح <b>كل</b> المستندات والحركات والأرصدة والفترات والمنتجات وسجل الـ Import والـ Audit، ويرجّع الترقيم من 1، فالنظام يبقى كأنه جديد.
        بيفضل: المستخدمين وصلاحياتهم، المطابخ، وأسباب Waste/Adjustments. <b>مفيش رجوع</b> — نزّل Backup الصفحات الأول لو محتاج الداتا.
      </p>
      <div className="form-row">
        <label className="field"><span>كلمة السر</span><input type="password" value={pw} autoComplete="off" onChange={(e) => setPw(e.target.value)} /></label>
        <label className="checks"><span><input type="checkbox" checked={sure} onChange={(e) => setSure(e.target.checked)} /> فاهم إن ده هيمسح كل البيانات نهائيًا</span></label>
        <button className="btn danger" disabled={busy || !sure || !pw} onClick={go}>{busy ? 'Deleting…' : 'Delete all data'}</button>
      </div>
      {msg && <div className={`alert ${msg.kind}`} style={{ marginTop: 10 }}>{msg.text}</div>}
    </div>
  );
}

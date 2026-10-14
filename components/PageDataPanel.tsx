'use client';
import { useMemo, useState } from 'react';
import { Eraser } from 'lucide-react';
import { createClient } from '@/lib/supabase/client';
import { useScope } from '@/components/ScopeProvider';
import { clearPagePhrase } from '@/lib/archive';

// الصفحات اللي ليها رصيد (مشتريات، هالك…) بتتمسح بالأرشفة بالشهور فوق لأنها محتاجة ترحيل رصيد.
const PAGES = [{ key: 'import_errors', label: 'Import Errors (أخطاء الرفع)' }];

// مسح بيانات صفحة معينة (Admin): لمطبخ واحد أو كل المطابخ، ومن عمر معيّن
export default function PageDataPanel() {
  const supabase = useMemo(() => createClient(), []);
  const { kitchens } = useScope();
  const [page, setPage] = useState(PAGES[0].key);
  const [sel, setSel] = useState('ALL');
  const [days, setDays] = useState('0');
  const [rows, setRows] = useState<number | null>(null);
  const [confirm, setConfirm] = useState('');
  const [busy, setBusy] = useState<string | null>(null);
  const [msg, setMsg] = useState<{ kind: 'ok' | 'err'; text: string } | null>(null);
  const one = sel === 'ALL' ? null : kitchens.find((k) => k.id === sel) ?? null;
  const older = Math.max(0, Math.floor(Number(days) || 0));
  const phrase = clearPagePhrase(page, one?.code);
  const reset = () => { setRows(null); setConfirm(''); };

  async function check() {
    setBusy('check'); setMsg(null); setConfirm('');
    const { data, error } = await supabase.rpc('page_data_preview', { p_page: page, p_kitchen: one?.id ?? null, p_older_days: older });
    if (error) setMsg({ kind: 'err', text: error.message }); else setRows((data as { rows: number }).rows);
    setBusy(null);
  }
  async function clear() {
    setBusy('clear'); setMsg(null);
    const { data, error } = await supabase.rpc('purge_page_data', { p_page: page, p_kitchen: one?.id ?? null, p_older_days: older, p_confirm: confirm });
    if (error) setMsg({ kind: 'err', text: error.message });
    else { setMsg({ kind: 'ok', text: `اتمسح ${(data as { rows_deleted: number }).rows_deleted.toLocaleString()} صف` }); reset(); }
    setBusy(null);
  }

  return (
    <div className="panel" style={{ marginTop: 16 }} dir="auto">
      <h2 style={{ display: 'flex', gap: 8, alignItems: 'center' }}><Eraser size={18} /> مسح بيانات صفحة معينة (Admin)</h2>
      <p className="muted">
        بتمسح سجل صفحة (حاليًا أخطاء الرفع Import Errors) لمطبخ واحد أو لكل المطابخ، وممكن تمسح الأقدم من عدد أيام بس. مفيش تأثير على الأرصدة ولا المستندات. الصفحات اللي وراها أرصدة (مشتريات، هالك، جرد…) بتتمسح بالأرشفة بالشهور فوق.
      </p>
      <div className="form-row">
        <label className="field"><span>Page</span>
          <select value={page} onChange={(e) => { setPage(e.target.value); reset(); }}>{PAGES.map((p) => <option key={p.key} value={p.key}>{p.label}</option>)}</select></label>
        <label className="field"><span>Kitchen</span>
          <select value={sel} onChange={(e) => { setSel(e.target.value); reset(); }}>
            <option value="ALL">All kitchens (+ أخطاء Data Product)</option>
            {kitchens.map((k) => <option key={k.id} value={k.id}>{k.name}</option>)}</select></label>
        <label className="field" style={{ width: 170 }}><span>أقدم من (أيام) — 0 = الكل</span>
          <input type="number" min={0} value={days} onChange={(e) => { setDays(e.target.value); reset(); }} /></label>
        <button className="btn secondary" disabled={!!busy} onClick={check}>{busy === 'check' ? 'Checking…' : '1) Check'}</button>
      </div>
      {rows !== null && (
        <div style={{ marginTop: 10 }}>
          <div className="muted">هيتمسح: <b>{rows.toLocaleString()}</b> صف</div>
          {rows > 0 && (
            <div className="form-row" style={{ marginTop: 8 }}>
              <label className="field" style={{ minWidth: 340 }}><span>اكتب للتأكيد: <b dir="ltr">{phrase}</b></span>
                <input type="text" dir="ltr" value={confirm} onChange={(e) => setConfirm(e.target.value)} /></label>
              <button className="btn" style={{ background: 'var(--err)' }} disabled={confirm !== phrase || !!busy} onClick={clear}>
                <Eraser size={14} /> {busy === 'clear' ? 'Deleting…' : '2) Delete'}</button>
            </div>
          )}
        </div>
      )}
      {msg && <div className={`alert ${msg.kind}`} style={{ marginTop: 10 }}>{msg.text}</div>}
    </div>
  );
}

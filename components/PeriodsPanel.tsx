'use client';
import { useCallback, useEffect, useMemo, useState } from 'react';
import { Lock, Unlock } from 'lucide-react';
import { createClient } from '@/lib/supabase/client';
import { useScope } from '@/components/ScopeProvider';
import { buildArchive } from '@/lib/archive';
import { saveBlob } from '@/lib/export';
import { monthRange, prevMonth } from '@/lib/months';

type P = { id: string; from_date: string; to_date: string; status: 'OPEN' | 'CLOSED'; closed_at: string | null; reopen_reason: string | null };

// قفل الفترات للمطبخ المختار: بعد القفل مفيش إدخال/تعديل بتاريخ رجعي إلا للـ Admin وبسبب مسجّل
export default function PeriodsPanel({ canManage, isAdmin }: { canManage: boolean; isAdmin: boolean }) {
  const supabase = useMemo(() => createClient(), []);
  const { kitchenId, kitchen } = useScope();
  const [rows, setRows] = useState<P[]>([]);
  const [msg, setMsg] = useState<{ kind: 'ok' | 'err'; text: string } | null>(null);
  const [mFrom, setMFrom] = useState(prevMonth());
  const [mTo, setMTo] = useState(prevMonth());
  const [step, setStep] = useState<'idle' | 'downloading' | 'confirm'>('idle');
  const [progress, setProgress] = useState('');
  const range = monthRange(mFrom, mTo);
  const [reopen, setReopen] = useState<P | null>(null);
  const [reason, setReason] = useState('');

  const load = useCallback(async () => {
    const { data, error } = await supabase.from('periods').select('id,from_date,to_date,status,closed_at,reopen_reason')
      .eq('kitchen_id', kitchenId).order('from_date', { ascending: false }).limit(24);
    if (error) setMsg({ kind: 'err', text: error.message }); else setRows((data ?? []) as P[]);
  }, [supabase, kitchenId]);
  useEffect(() => { load(); }, [load]);

  // 1) تنزيل صفحات المطبخ للفترة (Excel) 2) تأكيد 3) القفل
  async function startClose() {
    if (!range || !kitchen) return;
    setMsg(null); setStep('downloading'); setProgress('Starting…');
    try {
      const a = await buildArchive(supabase, { kitchens: [kitchen], from: range.from, to: range.to, onProgress: setProgress });
      saveBlob(a.blob, a.name);
      setStep('confirm');
    } catch (e) { setStep('idle'); setMsg({ kind: 'err', text: `التنزيل فشل — الفترة ما اتقفلتش: ${e instanceof Error ? e.message : String(e)}` }); }
  }

  async function confirmClose() {
    if (!range) return;
    const { error } = await supabase.rpc('close_period', { p_kitchen: kitchenId, p_from: range.from, p_to: range.to });
    setStep('idle');
    if (error) setMsg({ kind: 'err', text: error.message.includes('conflicting') ? 'الفترة دي بتتداخل مع فترة مقفولة قبل كده' : error.message });
    else { setMsg({ kind: 'ok', text: `اتقفلت الفترة ${range.from} → ${range.to} للمطبخ ${kitchen?.name}` }); await load(); }
  }

  async function doReopen() {
    if (!reopen) return;
    const { error } = await supabase.rpc('reopen_period', { p_period: reopen.id, p_reason: reason });
    if (error) setMsg({ kind: 'err', text: error.message });
    else { setMsg({ kind: 'ok', text: 'اتفتحت الفترة' }); setReopen(null); setReason(''); await load(); }
  }

  return (
    <details className="panel" style={{ padding: '10px 14px' }}>
      <summary style={{ cursor: 'pointer', fontWeight: 600 }}>Period lock · {kitchen?.name}
        {rows.filter((r) => r.status === 'CLOSED').length > 0 && <span className="badge err" style={{ marginLeft: 8 }}>{rows.filter((r) => r.status === 'CLOSED').length} closed</span>}
      </summary>
      <div style={{ marginTop: 10 }}>
        {msg && <div className={`alert ${msg.kind}`} style={{ marginBottom: 10 }} dir="auto">{msg.text}</div>}
        {canManage && (
          <div style={{ marginBottom: 10 }} dir="auto">
            <div className="form-row">
              <label className="field"><span>From month</span><input type="month" value={mFrom} max={mTo} disabled={step !== 'idle'} onChange={(e) => setMFrom(e.target.value)} /></label>
              <label className="field"><span>To month</span><input type="month" value={mTo} min={mFrom} disabled={step !== 'idle'} onChange={(e) => setMTo(e.target.value)} /></label>
              <button className="btn" disabled={!range || step !== 'idle'} onClick={startClose}><Lock size={14} /> {step === 'downloading' ? 'Downloading…' : 'Download pages & close'}</button>
              {step === 'downloading' && <span className="muted">{progress}</span>}
            </div>
            <div className="muted" style={{ marginTop: 6 }}>القفل بشهور كاملة بس{range ? ` (${range.from} → ${range.to})` : ''}. الأول بينزّل كل صفحات المطبخ للفترة دي Excel، وبعدها بيطلب تأكيد القفل. بعد القفل مفيش حد غير الـ Admin يضيف أو يعدّل أو يمسح فيها.</div>
            {step === 'confirm' && range && (
              <div className="alert warn" style={{ marginTop: 10 }}>
                <div>اتنزّل ملف الصفحات. تأكيد قفل <b>{range.from} → {range.to}</b> للمطبخ <b>{kitchen?.name}</b>؟</div>
                <div className="form-row" style={{ marginTop: 8 }}>
                  <button className="btn" onClick={confirmClose}><Lock size={14} /> Confirm close</button>
                  <button className="btn secondary" onClick={() => setStep('idle')}>Cancel</button>
                </div>
              </div>
            )}
          </div>
        )}
        {reopen && (
          <div className="form-row" style={{ marginBottom: 10 }}>
            <span dir="auto">إعادة فتح {reopen.from_date} → {reopen.to_date} — السبب:</span>
            <input type="text" value={reason} onChange={(e) => setReason(e.target.value)} dir="auto" style={{ width: 260 }} />
            <button className="btn small" disabled={!reason.trim()} onClick={doReopen}>Reopen</button>
            <button className="btn secondary small" onClick={() => setReopen(null)}>Cancel</button>
          </div>
        )}
        <table className="grid">
          <thead><tr><th>From</th><th>To</th><th>Status</th><th>Closed at</th><th>Reopen reason</th><th /></tr></thead>
          <tbody>
            {rows.map((r) => (
              <tr key={r.id}>
                <td>{r.from_date}</td><td>{r.to_date}</td>
                <td><span className={`badge ${r.status === 'CLOSED' ? 'err' : 'ok'}`}>{r.status}</span></td>
                <td className="muted">{r.closed_at ? new Date(r.closed_at).toLocaleString() : ''}</td>
                <td dir="auto" className="muted">{r.reopen_reason}</td>
                <td>{isAdmin && r.status === 'CLOSED' && <button className="btn secondary small" onClick={() => { setReopen(r); setMsg(null); }}><Unlock size={13} /> Reopen</button>}</td>
              </tr>
            ))}
            {!rows.length && <tr><td colSpan={6} className="empty">No locked periods</td></tr>}
          </tbody>
        </table>
      </div>
    </details>
  );
}

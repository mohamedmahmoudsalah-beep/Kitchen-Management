'use client';
import { useCallback, useEffect, useMemo, useState } from 'react';
import { Lock, Unlock } from 'lucide-react';
import { createClient } from '@/lib/supabase/client';
import { useScope } from '@/components/ScopeProvider';

type P = { id: string; from_date: string; to_date: string; status: 'OPEN' | 'CLOSED'; closed_at: string | null; reopen_reason: string | null };

// قفل الفترات للمطبخ المختار: بعد القفل مفيش إدخال/تعديل بتاريخ رجعي إلا للـ Admin وبسبب مسجّل
export default function PeriodsPanel({ canManage, isAdmin }: { canManage: boolean; isAdmin: boolean }) {
  const supabase = useMemo(() => createClient(), []);
  const { kitchenId, kitchen, from, to } = useScope();
  const [rows, setRows] = useState<P[]>([]);
  const [msg, setMsg] = useState<{ kind: 'ok' | 'err'; text: string } | null>(null);
  const [pFrom, setPFrom] = useState(from);
  const [pTo, setPTo] = useState(to);
  const [reopen, setReopen] = useState<P | null>(null);
  const [reason, setReason] = useState('');

  useEffect(() => { setPFrom(from); setPTo(to); }, [from, to]);

  const load = useCallback(async () => {
    const { data, error } = await supabase.from('periods').select('id,from_date,to_date,status,closed_at,reopen_reason')
      .eq('kitchen_id', kitchenId).order('from_date', { ascending: false }).limit(24);
    if (error) setMsg({ kind: 'err', text: error.message }); else setRows((data ?? []) as P[]);
  }, [supabase, kitchenId]);
  useEffect(() => { load(); }, [load]);

  async function close() {
    setMsg(null);
    const { error } = await supabase.rpc('close_period', { p_kitchen: kitchenId, p_from: pFrom, p_to: pTo });
    if (error) setMsg({ kind: 'err', text: error.message.includes('conflicting') ? 'الفترة دي بتتداخل مع فترة مقفولة قبل كده' : error.message });
    else { setMsg({ kind: 'ok', text: `اتقفلت الفترة ${pFrom} → ${pTo} للمطبخ ${kitchen?.name}` }); await load(); }
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
          <div className="form-row" style={{ marginBottom: 10 }}>
            <label className="field"><span>From</span><input type="date" value={pFrom} onChange={(e) => setPFrom(e.target.value)} /></label>
            <label className="field"><span>To</span><input type="date" value={pTo} min={pFrom} onChange={(e) => setPTo(e.target.value)} /></label>
            <button className="btn" onClick={close}><Lock size={14} /> Close period</button>
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

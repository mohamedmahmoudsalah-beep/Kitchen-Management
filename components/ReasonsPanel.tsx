'use client';
import { useCallback, useEffect, useMemo, useState } from 'react';
import { Plus } from 'lucide-react';
import { createClient } from '@/lib/supabase/client';
import type { Reason } from '@/lib/types';

const DIR_LABEL: Record<Reason['direction'], string> = { INCREASE: 'Increase +', DECREASE: 'Decrease −', ANY: 'Either ±' };
const DIR_CLASS: Record<Reason['direction'], string> = { INCREASE: 'ok', DECREASE: 'err', ANY: 'warn' };

// قايمة الأسباب المشتركة بين Waste و Stock Adjustments. أي مستخدم (مش Viewer) يقدر يضيف سبب.
export default function ReasonsPanel({ canAdd, isAdmin, compact = false }: { canAdd: boolean; isAdmin: boolean; compact?: boolean }) {
  const supabase = useMemo(() => createClient(), []);
  const [reasons, setReasons] = useState<Reason[]>([]);
  const [adding, setAdding] = useState(false);
  const [name, setName] = useState('');
  const [direction, setDirection] = useState<Reason['direction']>('DECREASE');
  const [msg, setMsg] = useState<{ kind: 'ok' | 'err'; text: string } | null>(null);
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    const { data, error } = await supabase.from('reasons').select('id,name,direction,is_active,is_system').order('created_at');
    if (error) setMsg({ kind: 'err', text: error.message }); else setReasons((data ?? []) as Reason[]);
  }, [supabase]);
  useEffect(() => { load(); }, [load]);

  async function add() {
    setBusy(true); setMsg(null);
    const { error } = await supabase.rpc('add_reason', { p_name: name, p_direction: direction });
    setBusy(false);
    if (error) { setMsg({ kind: 'err', text: error.message }); return; }
    setMsg({ kind: 'ok', text: `اتضاف السبب "${name.trim()}"` }); setName(''); setAdding(false); await load();
  }

  async function toggle(r: Reason) {
    const { error } = await supabase.rpc('set_reason_active', { p_id: r.id, p_active: !r.is_active });
    if (error) setMsg({ kind: 'err', text: error.message }); else await load();
  }

  const body = (
    <>
      <div className="checks" style={{ gap: '6px 8px' }}>
        {reasons.map((r) => (
          <span key={r.id} className={`badge ${r.is_active ? DIR_CLASS[r.direction] : ''}`}
            style={{ opacity: r.is_active ? 1 : 0.5, padding: '3px 10px' }} dir="auto">
            {r.name} · {DIR_LABEL[r.direction]}{!r.is_active && ' · off'}
            {isAdmin && (
              <button className="icon-btn" style={{ color: 'inherit', display: 'inline', padding: '0 0 0 6px' }}
                onClick={() => toggle(r)} title={r.is_active ? 'Deactivate' : 'Activate'}>{r.is_active ? '×' : '↺'}</button>
            )}
          </span>
        ))}
        {canAdd && !adding && (
          <button className="btn secondary small" onClick={() => { setAdding(true); setMsg(null); }}><Plus size={13} /> Add reason</button>
        )}
      </div>
      {adding && (
        <div className="form-row" style={{ marginTop: 10 }}>
          <label className="field"><span>Reason name</span>
            <input type="text" value={name} onChange={(e) => setName(e.target.value)} dir="auto" maxLength={60} autoFocus />
          </label>
          <label className="field"><span>Effect on stock</span>
            <select value={direction} onChange={(e) => setDirection(e.target.value as Reason['direction'])}>
              <option value="DECREASE">Decrease (نقص)</option>
              <option value="INCREASE">Increase (زيادة)</option>
              <option value="ANY">Either (زيادة أو نقص)</option>
            </select>
          </label>
          <button className="btn" disabled={busy || name.trim().length < 2} onClick={add}>Save reason</button>
          <button className="btn secondary" onClick={() => setAdding(false)}>Cancel</button>
        </div>
      )}
      {msg && <div className={`alert ${msg.kind}`} style={{ marginTop: 10 }} dir="auto">{msg.text}</div>}
    </>
  );

  if (compact) {
    return (
      <details className="panel" style={{ padding: '10px 14px' }}>
        <summary style={{ cursor: 'pointer', fontWeight: 600 }}>Reasons list ({reasons.filter((r) => r.is_active).length}) — Waste / Stock Adjustments</summary>
        <div style={{ marginTop: 10 }}>{body}</div>
      </details>
    );
  }
  return (
    <div className="panel">
      <h2>Reasons</h2>
      <p className="muted" style={{ marginTop: 0 }} dir="auto">
        قايمة واحدة للـ Waste والـ Stock Adjustments. الاتجاه بيحدد الإشارة: Increase = كمية موجبة، Decrease = سالبة (وفي Waste بتتسجل كخروج)، Either = أي إشارة.
      </p>
      {body}
    </div>
  );
}

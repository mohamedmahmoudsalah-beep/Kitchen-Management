'use client';
import { Fragment, useCallback, useEffect, useMemo, useState } from 'react';
import Link from 'next/link';
import { ChevronDown, ChevronRight, FileUp, Pencil, Plus, Undo2 } from 'lucide-react';
import { createClient } from '@/lib/supabase/client';
import { useScope } from '@/components/ScopeProvider';
import DocumentEditor from '@/components/DocumentEditor';
import DocumentLines from '@/components/DocumentLines';
import TemplateButton from '@/components/TemplateButton';
import { fmt, toBase, toPieces, type QtyMode } from '@/lib/qty';
import { ymd } from '@/lib/export';

type TRow = {
  id: string; doc_no: string; doc_date: string; status: string; kitchen_id: string; counterpart_kitchen_id: string | null;
  note: string | null; document_lines: { count: number }[];
};

const STATUS: Record<string, { cls: string; label: string }> = {
  DRAFT: { cls: 'warn', label: 'Draft' },
  PENDING_RECEIPT: { cls: 'magenta', label: 'Pending receipt' },
  COMPLETED: { cls: 'ok', label: 'Completed' },
  RETURN_PENDING: { cls: 'warn', label: 'Return pending' },
  CLOSED_PARTIAL: { cls: 'ok', label: 'Closed (partial)' },
  REVERSED: { cls: 'err', label: 'Cancelled' },
  POSTED: { cls: '', label: 'Cancellation' },
};

type DLine = {
  id: string; line_no: number; uom_factor_snapshot: number;
  products: { syt_code: string; name: string };
  transfer_lines: { sent_base: number; received_base: number | null; returned_base: number }[] | { sent_base: number; received_base: number | null; returned_base: number } | null;
};

// استلام (بالكمية الفعلية) أو تأكيد مرتجع
function QtyDialog({ kind, doc, onClose, onDone, isAdmin, canAdjust }: {
  kind: 'receive' | 'return'; doc: TRow; onClose: () => void; onDone: (m: string) => void; isAdmin: boolean; canAdjust: boolean;
}) {
  const supabase = useMemo(() => createClient(), []);
  const [lines, setLines] = useState<DLine[]>([]);
  const [vals, setVals] = useState<Record<string, string>>({});
  const [mode, setMode] = useState<QtyMode>('BASE');
  const [date, setDate] = useState(ymd(new Date()));
  const [override, setOverride] = useState('');
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const tl = (l: DLine) => (Array.isArray(l.transfer_lines) ? l.transfer_lines[0] : l.transfer_lines)!;
  const sent = (l: DLine) => Number(tl(l).sent_base);
  const pendingReturn = (l: DLine) => sent(l) - Number(tl(l).received_base ?? sent(l)) - Number(tl(l).returned_base);

  useEffect(() => {
    supabase.from('document_lines')
      .select('id,line_no,uom_factor_snapshot,products(syt_code,name),transfer_lines(sent_base,received_base,returned_base)')
      .eq('document_id', doc.id).order('line_no')
      .then(({ data, error }) => {
        if (error) { setErr(error.message); return; }
        const ls = (data ?? []) as unknown as DLine[];
        setLines(ls);
        const v: Record<string, string> = {};
        ls.forEach((l) => {
          const t = Array.isArray(l.transfer_lines) ? l.transfer_lines[0] : l.transfer_lines;
          const base = kind === 'receive' ? Number(t!.sent_base) : Number(t!.sent_base) - Number(t!.received_base ?? t!.sent_base) - Number(t!.returned_base);
          v[l.id] = String(base);
        });
        setVals(v);
      });
  }, [supabase, doc.id, kind]);

  function changeMode(m: QtyMode) {
    const next: Record<string, string> = {};
    lines.forEach((l) => {
      const f = Number(l.uom_factor_snapshot);
      const base = toBase(Number(vals[l.id] || 0), mode, f);
      next[l.id] = String(m === 'PIECE' ? toPieces(base, f) : base);
    });
    setVals(next); setMode(m);
  }

  const baseOf = (l: DLine) => toBase(Number(vals[l.id] || 0), mode, Number(l.uom_factor_snapshot));
  const max = (l: DLine) => (kind === 'receive' ? sent(l) : pendingReturn(l));
  const bad = lines.some((l) => !Number.isFinite(Number(vals[l.id] || 0)) || Number(vals[l.id] || 0) < 0 || baseOf(l) > max(l) + 1e-9);
  const anyQty = lines.some((l) => baseOf(l) > 0);

  async function submit() {
    setBusy(true); setErr(null);
    const payload = lines.filter((l) => kind === 'receive' || baseOf(l) > 0)
      .map((l) => ({ line_id: l.id, qty: vals[l.id] || '0', mode }));
    const { error } = await supabase.rpc(kind === 'receive' ? 'receive_transfer' : 'confirm_return',
      { p_doc: doc.id, p_lines: payload, p_date: date, p_override: override.trim() || null });
    setBusy(false);
    if (error) setErr(error.message);
    else onDone(kind === 'receive' ? `اتأكد استلام ${doc.doc_no}` : `اتأكد المرتجع على ${doc.doc_no}`);
  }

  async function writeOff() {
    if (!window.confirm('الكمية المعلقة مرجعتش فعلًا؟ هترجع استوك عند المرسل وبعدها تتسجل Missing (تسوية نقص).')) return;
    setBusy(true); setErr(null);
    const { error } = await supabase.rpc('write_off_return', { p_doc: doc.id, p_date: date, p_override: override.trim() || null });
    setBusy(false);
    if (error) setErr(error.message); else onDone(`المرتجع المعلق على ${doc.doc_no} رجع استوك واتسجل Missing`);
  }

  return (
    <div className="panel" style={{ borderColor: 'var(--magenta)' }}>
      <div className="page-head" style={{ marginBottom: 8 }}>
        <h2 style={{ margin: 0 }}>{kind === 'receive' ? 'Confirm receipt' : 'Confirm return'} · {doc.doc_no}</h2>
        <span className="spacer" />
        <button className="btn secondary small" onClick={onClose}>Close</button>
      </div>
      <p className="muted" style={{ marginTop: 0 }} dir="auto">
        {kind === 'receive'
          ? 'اكتب الكمية الفعلية اللي استلمتها لكل سطر. الفرق عن المرسل بيفضل Return Pending عند المرسل لحد ما يأكد استلامه.'
          : 'اكتب الكمية اللي رجعتلك فعلًا. ممكن تأكد على دفعات، والتحويل بيتقفل لما كل المرتجع يرجع.'}
      </p>
      <div className="form-row">
        <label className="field"><span>Date</span><input type="date" value={date} onChange={(e) => setDate(e.target.value)} /></label>
        <label className="field"><span>Quantities in</span>
          <select value={mode} onChange={(e) => changeMode(e.target.value as QtyMode)}>
            <option value="BASE">Base (kg)</option><option value="PIECE">Syt pcs</option>
          </select>
        </label>
        {isAdmin && <label className="field" style={{ minWidth: 220 }}><span>Override reason (closed period)</span>
          <input type="text" value={override} onChange={(e) => setOverride(e.target.value)} dir="auto" /></label>}
      </div>
      <div className="table-wrap" style={{ marginTop: 10 }}>
        <table className="grid">
          <thead><tr><th>#</th><th>Product</th>
            <th className="num">{kind === 'receive' ? 'Sent' : 'Pending return'}</th><th>{kind === 'receive' ? 'Received' : 'Returned now'}</th>
            <th className="num">{kind === 'receive' ? 'Shortfall → return pending' : 'Remaining after'}</th></tr></thead>
          <tbody>
            {lines.map((l) => {
              const f = Number(l.uom_factor_snapshot);
              const m = max(l);
              const b = baseOf(l);
              return (
                <tr key={l.id}>
                  <td>{l.line_no}</td>
                  <td><span className="mono">{l.products.syt_code}</span> <span dir="auto">{l.products.name}</span></td>
                  <td className="num">{fmt(m)}{f !== 1 && <span className="muted"> ({fmt(toPieces(m, f))} pcs)</span>}</td>
                  <td>
                    <input type="text" inputMode="decimal" value={vals[l.id] ?? ''} style={{ width: 90, borderColor: b > m + 1e-9 ? 'var(--err)' : undefined }}
                      onChange={(e) => setVals({ ...vals, [l.id]: e.target.value })} />
                    <span className="muted" style={{ marginLeft: 6 }}>= {fmt(b)}{f !== 1 && ` · ${fmt(toPieces(b, f))} pcs`}</span>
                  </td>
                  <td className="num">{fmt(Math.max(0, m - b))}</td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
      {err && <div className="alert err" style={{ marginTop: 10 }} dir="auto">{err}</div>}
      <div className="form-row" style={{ marginTop: 12 }}>
        <button className="btn" disabled={busy || bad || (kind === 'return' && !anyQty)} onClick={submit}>
          {kind === 'receive' ? 'Confirm receipt' : 'Confirm return'}
        </button>
        {kind === 'return' && canAdjust && (
          <button className="btn danger" disabled={busy} onClick={writeOff} title="يرجّع الكمية المعلقة استوك وبعدين ينزّلها Missing">
            Not coming back → return to stock &amp; book as Missing
          </button>
        )}
      </div>
    </div>
  );
}

export default function TransfersView({ canWrite, canReverse, isAdmin, canImport, canAdjust }: {
  canWrite: boolean; canReverse: boolean; isAdmin: boolean; canImport: boolean; canAdjust: boolean;
}) {
  const supabase = useMemo(() => createClient(), []);
  const { kitchenId, kitchen, kitchens, from, to } = useScope();
  const [tab, setTab] = useState<'out' | 'in'>('out');
  const [rows, setRows] = useState<TRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [msg, setMsg] = useState<{ kind: 'ok' | 'err'; text: string } | null>(null);
  const [open, setOpen] = useState<string | null>(null);
  const [editor, setEditor] = useState<{ id: string | null } | null>(null);
  const [dialog, setDialog] = useState<{ kind: 'receive' | 'return'; doc: TRow } | null>(null);
  const [cancel, setCancel] = useState<TRow | null>(null);
  const [reason, setReason] = useState('');

  const name = (id: string | null) => kitchens.find((k) => k.id === id)?.name ?? '—';

  const load = useCallback(async () => {
    setLoading(true);
    let q = supabase.from('documents')
      .select('id,doc_no,doc_date,status,kitchen_id,counterpart_kitchen_id,note,document_lines(count)')
      .eq('doc_type', 'TRANSFER').is('reverses_document_id', null)
      // اللي في الفترة + أي حاجة لسه مفتوحة (مستني استلام / مرتجع معلق) حتى لو برا الفترة
      .or(`and(doc_date.gte.${from},doc_date.lte.${to}),status.in.(PENDING_RECEIPT,RETURN_PENDING)`)
      .order('doc_date', { ascending: false }).order('created_at', { ascending: false }).limit(500);
    q = tab === 'out' ? q.eq('kitchen_id', kitchenId) : q.eq('counterpart_kitchen_id', kitchenId).neq('status', 'DRAFT');
    const { data, error } = await q;
    if (error) setMsg({ kind: 'err', text: error.message }); else setRows((data ?? []) as unknown as TRow[]);
    setLoading(false);
  }, [supabase, kitchenId, from, to, tab]);

  useEffect(() => { load(); setEditor(null); setDialog(null); setCancel(null); }, [load]);

  async function doCancel() {
    if (!cancel) return;
    const { error } = await supabase.rpc('reverse_document', { p_doc: cancel.id, p_reason: reason });
    if (error) setMsg({ kind: 'err', text: error.message });
    else { setMsg({ kind: 'ok', text: `اتلغى التحويل ${cancel.doc_no}` }); setCancel(null); setReason(''); await load(); }
  }

  const done = (text: string) => { setEditor(null); setDialog(null); setMsg({ kind: 'ok', text }); load(); };

  return (
    <>
      {editor && kitchen && (
        <DocumentEditor key={editor.id ?? 'new'} docType="TRANSFER" kitchenId={kitchenId} kitchenName={kitchen.name} kitchens={kitchens}
          docId={editor.id} isAdmin={isAdmin} defaultDate={to} onClose={() => setEditor(null)} onChanged={done} />
      )}
      {dialog && <QtyDialog kind={dialog.kind} doc={dialog.doc} isAdmin={isAdmin} canAdjust={canAdjust} onClose={() => setDialog(null)} onDone={done} />}

      <div className="panel flush">
        <div className="toolbar">
          <div className="tabs" style={{ borderBottom: 0 }}>
            <button className={`tab ${tab === 'out' ? 'active' : ''}`} onClick={() => setTab('out')}>Outgoing</button>
            <button className={`tab ${tab === 'in' ? 'active' : ''}`} onClick={() => setTab('in')}>Incoming</button>
          </div>
          <span className="muted" dir="auto">{kitchen?.name} · {tab === 'out' ? 'محوّل منه' : 'محوّل إليه'} · {rows.length}</span>
          <span className="spacer" />
          {canImport && <TemplateButton module="transfers" />}
          {canImport && <Link className="btn secondary" href="/import-export?module=transfers"><FileUp size={14} /> Import from file</Link>}
          {canWrite && <button className="btn" onClick={() => { setEditor({ id: null }); setDialog(null); setMsg(null); setTab('out'); }}><Plus size={14} /> New transfer</button>}
        </div>
        {msg && <div className={`alert ${msg.kind}`} style={{ margin: 12 }} dir="auto">{msg.text}</div>}
        {cancel && (
          <div className="toolbar" style={{ background: 'var(--warn-soft)' }}>
            <span dir="auto">إلغاء <b>{cancel.doc_no}</b> (لسه ما اتستلمش) — السبب:</span>
            <input type="text" value={reason} onChange={(e) => setReason(e.target.value)} dir="auto" style={{ width: 260 }} autoFocus />
            <button className="btn small" disabled={!reason.trim()} onClick={doCancel}>Confirm</button>
            <button className="btn secondary small" onClick={() => { setCancel(null); setReason(''); }}>Cancel</button>
          </div>
        )}
        <div className="table-wrap">
          <table className="grid">
            <thead><tr><th style={{ width: 28 }} /><th>Doc No</th><th>Date</th><th>From</th><th>To</th><th>Status</th><th className="num">Lines</th><th>Note</th><th /></tr></thead>
            <tbody>
              {rows.map((r) => {
                const st = STATUS[r.status] ?? { cls: '', label: r.status };
                return (
                  <Fragment key={r.id}>
                    <tr>
                      <td><button className="icon-btn" style={{ color: 'var(--muted)' }} onClick={() => setOpen(open === r.id ? null : r.id)}>
                        {open === r.id ? <ChevronDown size={14} /> : <ChevronRight size={14} />}</button></td>
                      <td className="mono">{r.doc_no}</td><td>{r.doc_date}</td>
                      <td>{name(r.kitchen_id)}</td><td>{name(r.counterpart_kitchen_id)}</td>
                      <td><span className={`badge ${st.cls}`}>{st.label}</span></td>
                      <td className="num">{r.document_lines?.[0]?.count ?? 0}</td>
                      <td dir="auto" className="muted">{r.note}</td>
                      <td style={{ whiteSpace: 'nowrap' }}>
                        {tab === 'out' && canWrite && r.status === 'DRAFT' && (
                          <button className="btn secondary small" onClick={() => { setEditor({ id: r.id }); setDialog(null); setMsg(null); }}><Pencil size={12} /> Edit / Send</button>
                        )}
                        {tab === 'out' && canWrite && r.status === 'RETURN_PENDING' && (
                          <button className="btn small" onClick={() => { setDialog({ kind: 'return', doc: r }); setEditor(null); setMsg(null); }}>Confirm return</button>
                        )}
                        {tab === 'out' && canReverse && r.status === 'PENDING_RECEIPT' && (
                          <button className="btn danger small" onClick={() => { setCancel(r); setMsg(null); }}><Undo2 size={13} /> Cancel</button>
                        )}
                        {tab === 'in' && canWrite && r.status === 'PENDING_RECEIPT' && (
                          <button className="btn small" onClick={() => { setDialog({ kind: 'receive', doc: r }); setEditor(null); setMsg(null); }}>Confirm receipt</button>
                        )}
                      </td>
                    </tr>
                    {open === r.id && <tr><td colSpan={9} style={{ background: '#fafbfd', padding: 8 }}><DocumentLines docId={r.id} transfer /></td></tr>}
                  </Fragment>
                );
              })}
              {!rows.length && <tr><td colSpan={9} className="empty">{loading ? 'Loading…' : tab === 'out' ? 'No outgoing transfers' : 'No incoming transfers'}</td></tr>}
            </tbody>
          </table>
        </div>
      </div>
    </>
  );
}

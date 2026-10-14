'use client';
import { Fragment, useEffect, useMemo, useState } from 'react';
import { Pencil } from 'lucide-react';
import { createClient } from '@/lib/supabase/client';
import Qty from '@/components/Qty';
import LineEditForm, { type LineEditRow } from '@/components/LineEditForm';
import type { ProductLite } from '@/components/ProductPicker';

type Row = {
  line_no: number; qty_input: number; input_mode: 'PIECE' | 'BASE'; qty_pieces: number; qty_base: number; reason: string | null; reason_id: string | null; note: string | null;
  uom_factor_snapshot: number; unit_cost_snapshot: number | null;
  products: { id: string; syt_code: string; generic_code: string | null; name: string; uom_factor: number; cost_per_uom: number } | null;
  transfer_lines: { sent_base: number; received_base: number | null; returned_base: number }[] | { sent_base: number; received_base: number | null; returned_base: number } | null;
};
type Edit = { line_no: number; edited_at: string; edited_by_email: string | null; reason: string; old_data: { product?: string; qty_base?: number }; new_data: { product?: string; qty_base?: number }; period_override: boolean };

// تفاصيل سطور مستند (بتظهر الكميتين: الوحدة الأساسية + عدد القطع). لو edit متبعت: زرار تعديل لكل سطر (المستندات Posted بس).
export default function DocumentLines({ docId, transfer = false, edit }: {
  docId: string; transfer?: boolean; edit?: { docType: string; onChanged: (text: string) => void };
}) {
  const supabase = useMemo(() => createClient(), []);
  const [rows, setRows] = useState<Row[] | null>(null);
  const [edits, setEdits] = useState<Edit[]>([]);
  const [err, setErr] = useState<string | null>(null);
  const [editing, setEditing] = useState<number | null>(null);
  const [ver, setVer] = useState(0);

  useEffect(() => {
    supabase.from('document_lines')
      .select('line_no,qty_input,input_mode,qty_pieces,qty_base,reason,reason_id,note,uom_factor_snapshot,unit_cost_snapshot,products(id,syt_code,generic_code,name,uom_factor,cost_per_uom),transfer_lines(sent_base,received_base,returned_base)')
      .eq('document_id', docId).order('line_no')
      .then(({ data, error }) => { if (error) setErr(error.message); else setRows((data ?? []) as unknown as Row[]); });
    if (!transfer) {
      supabase.from('document_line_edits').select('line_no,edited_at,edited_by_email,reason,old_data,new_data,period_override')
        .eq('document_id', docId).order('id')
        .then(({ data }) => setEdits((data ?? []) as Edit[]));
    }
  }, [supabase, docId, transfer, ver]);

  if (err) return <div className="alert err">{err}</div>;
  if (!rows) return <div className="muted">Loading…</div>;
  const tl = (r: Row) => (Array.isArray(r.transfer_lines) ? r.transfer_lines[0] : r.transfer_lines) ?? null;
  const editsOf = (n: number) => edits.filter((e) => e.line_no === n);
  const cols = 8 + (transfer ? 3 : 0) + (edit ? 1 : 0);

  return (
    <>
      <table className="grid" style={{ background: '#fff' }}>
        <thead><tr>
          <th>#</th><th>Product</th><th className="num">{transfer ? 'Sent' : 'Qty (base)'}</th>
          {transfer && <><th className="num">Received</th><th className="num">Returned</th><th className="num">Pending return</th></>}
          <th>Entered as</th><th>Reason</th><th>Note</th>{edit && <th />}
        </tr></thead>
        <tbody>
          {rows.map((r) => {
            const t = tl(r);
            const f = Number(r.uom_factor_snapshot);
            const done = editsOf(r.line_no);
            return (
              <Fragment key={r.line_no}>
                <tr>
                  <td>{r.line_no}</td>
                  <td>
                    <span className="mono">{r.products?.syt_code}</span> <span dir="auto">{r.products?.name}</span>
                    {done.length > 0 && <span className="badge warn" style={{ marginLeft: 6 }} title={done.map((e) => `${e.edited_at.slice(0, 16).replace('T', ' ')} · ${e.edited_by_email ?? ''} · ${e.reason}`).join('\n')}>edited ×{done.length}</span>}
                  </td>
                  <td className="num"><Qty base={r.qty_base} factor={f} /></td>
                  {transfer && (
                    <>
                      <td className="num">{t?.received_base == null ? '—' : <Qty base={t.received_base} factor={f} />}</td>
                      <td className="num">{t ? <Qty base={t.returned_base} factor={f} /> : '—'}</td>
                      <td className="num">{t && t.received_base != null ? <Qty base={Number(t.sent_base) - Number(t.received_base) - Number(t.returned_base)} factor={f} /> : '—'}</td>
                    </>
                  )}
                  <td className="muted">{Number(r.qty_input)} {r.input_mode === 'PIECE' ? 'pcs' : 'base'}</td>
                  <td dir="auto">{r.reason ?? ''}</td>
                  <td dir="auto" className="muted">{r.note ?? ''}</td>
                  {edit && (
                    <td style={{ whiteSpace: 'nowrap' }}>
                      <button className="btn secondary small" disabled={!r.products} onClick={() => setEditing(editing === r.line_no ? null : r.line_no)}><Pencil size={12} /> Edit</button>
                    </td>
                  )}
                </tr>
                {edit && editing === r.line_no && r.products && (
                  <tr><td colSpan={cols} style={{ background: '#fafbfd' }}>
                    <LineEditForm docId={docId} docType={edit.docType} onCancel={() => setEditing(null)}
                      row={{ line_no: r.line_no, product: r.products as ProductLite, qty_input: r.qty_input, input_mode: r.input_mode, qty_base: r.qty_base, reason_id: r.reason_id, note: r.note } satisfies LineEditRow}
                      onSaved={(text) => { setEditing(null); setVer((v) => v + 1); edit.onChanged(text); }} />
                  </td></tr>
                )}
              </Fragment>
            );
          })}
        </tbody>
      </table>
      {edits.length > 0 && (
        <details style={{ marginTop: 6 }} dir="auto">
          <summary className="muted" style={{ cursor: 'pointer' }}>سجل التعديلات ({edits.length})</summary>
          <table className="grid" style={{ background: '#fff', marginTop: 4 }}>
            <thead><tr><th>When</th><th>By</th><th className="num">Line</th><th>Before → After (base)</th><th>Why</th></tr></thead>
            <tbody>
              {edits.map((e, i) => (
                <tr key={i}>
                  <td>{e.edited_at.slice(0, 16).replace('T', ' ')}{e.period_override && <span className="badge warn" style={{ marginLeft: 4 }}>period override</span>}</td>
                  <td className="muted">{e.edited_by_email}</td><td className="num">{e.line_no}</td>
                  <td className="mono">{e.old_data.product} {Number(e.old_data.qty_base)} → {e.new_data.product} {Number(e.new_data.qty_base)}</td>
                  <td dir="auto">{e.reason}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </details>
      )}
    </>
  );
}

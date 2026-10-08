'use client';
import { useEffect, useMemo, useState } from 'react';
import { createClient } from '@/lib/supabase/client';
import Qty from '@/components/Qty';

type Row = {
  line_no: number; qty_input: number; input_mode: string; qty_pieces: number; qty_base: number; reason: string | null; note: string | null;
  uom_factor_snapshot: number; unit_cost_snapshot: number | null;
  products: { syt_code: string; name: string } | null;
  transfer_lines: { sent_base: number; received_base: number | null; returned_base: number }[] | { sent_base: number; received_base: number | null; returned_base: number } | null;
};

// تفاصيل سطور مستند (بتظهر الكميتين: الوحدة الأساسية + عدد القطع)
export default function DocumentLines({ docId, transfer = false }: { docId: string; transfer?: boolean }) {
  const supabase = useMemo(() => createClient(), []);
  const [rows, setRows] = useState<Row[] | null>(null);
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => {
    supabase.from('document_lines')
      .select('line_no,qty_input,input_mode,qty_pieces,qty_base,reason,note,uom_factor_snapshot,unit_cost_snapshot,products(syt_code,name),transfer_lines(sent_base,received_base,returned_base)')
      .eq('document_id', docId).order('line_no')
      .then(({ data, error }) => { if (error) setErr(error.message); else setRows((data ?? []) as unknown as Row[]); });
  }, [supabase, docId]);

  if (err) return <div className="alert err">{err}</div>;
  if (!rows) return <div className="muted">Loading…</div>;
  const tl = (r: Row) => (Array.isArray(r.transfer_lines) ? r.transfer_lines[0] : r.transfer_lines) ?? null;

  return (
    <table className="grid" style={{ background: '#fff' }}>
      <thead><tr>
        <th>#</th><th>Product</th><th className="num">{transfer ? 'Sent' : 'Qty (base)'}</th>
        {transfer && <><th className="num">Received</th><th className="num">Returned</th><th className="num">Pending return</th></>}
        <th>Entered as</th><th>Reason</th><th>Note</th>
      </tr></thead>
      <tbody>
        {rows.map((r) => {
          const t = tl(r);
          const f = Number(r.uom_factor_snapshot);
          return (
            <tr key={r.line_no}>
              <td>{r.line_no}</td>
              <td><span className="mono">{r.products?.syt_code}</span> <span dir="auto">{r.products?.name}</span></td>
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
            </tr>
          );
        })}
      </tbody>
    </table>
  );
}

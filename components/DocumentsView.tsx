'use client';
import { Fragment, useCallback, useEffect, useMemo, useState } from 'react';
import Link from 'next/link';
import { ChevronDown, ChevronRight, Download, FileUp, Pencil, Plus, Undo2 } from 'lucide-react';
import { createClient } from '@/lib/supabase/client';
import { useScope } from '@/components/ScopeProvider';
import DocumentEditor, { type EditorDocType } from '@/components/DocumentEditor';
import DocumentLines from '@/components/DocumentLines';
import TemplateButton from '@/components/TemplateButton';
import type { ImportModule } from '@/lib/import/columns';
import { downloadCsv, ymd } from '@/lib/export';
import type { DocumentRow } from '@/lib/types';

const STATUS_CLASS: Record<string, string> = { POSTED: 'ok', REVERSED: 'err', DRAFT: 'warn' };

// قايمة مستندات نوع واحد + إدخال يدوي (Draft -> Post) + Import + Reverse
export default function DocumentsView({ docType, importModule, canWrite, canReverse, canImport, isAdmin, manual }: {
  docType: string; importModule?: string; canWrite: boolean; canReverse: boolean; canImport: boolean; isAdmin: boolean; manual: boolean;
}) {
  const supabase = useMemo(() => createClient(), []);
  const { kitchenId, kitchen, kitchens, from, to } = useScope();
  const [rows, setRows] = useState<DocumentRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [msg, setMsg] = useState<{ kind: 'ok' | 'err'; text: string } | null>(null);
  const [rev, setRev] = useState<DocumentRow | null>(null);
  const [reason, setReason] = useState('');
  const [open, setOpen] = useState<string | null>(null);
  const [editor, setEditor] = useState<{ id: string | null } | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    const { data, error } = await supabase.from('documents')
      .select('id,doc_no,doc_type,doc_date,status,note,override_reason,reverses_document_id,created_at,document_lines(count)')
      .eq('kitchen_id', kitchenId).eq('doc_type', docType)
      .gte('doc_date', from).lte('doc_date', to)
      .order('doc_date', { ascending: false }).order('created_at', { ascending: false }).limit(500);
    if (error) setMsg({ kind: 'err', text: error.message }); else setRows((data ?? []) as unknown as DocumentRow[]);
    setLoading(false);
  }, [supabase, kitchenId, docType, from, to]);

  useEffect(() => { load(); setEditor(null); setRev(null); }, [load]);

  async function reverse() {
    if (!rev) return;
    const { error } = await supabase.rpc('reverse_document', { p_doc: rev.id, p_reason: reason });
    if (error) setMsg({ kind: 'err', text: error.message });
    else { setMsg({ kind: 'ok', text: `اتعمل Reverse للمستند ${rev.doc_no}` }); setRev(null); setReason(''); await load(); }
  }

  return (
    <>
      {editor && kitchen && (
        <DocumentEditor key={editor.id ?? 'new'} docType={docType as EditorDocType} kitchenId={kitchenId} kitchenName={kitchen.name}
          kitchens={kitchens} docId={editor.id} isAdmin={isAdmin} defaultDate={to}
          onClose={() => setEditor(null)} onChanged={(text) => { setEditor(null); setMsg({ kind: 'ok', text }); load(); }} />
      )}
      <div className="panel flush">
        <div className="toolbar">
          <span className="muted" dir="auto">{kitchen?.name} · {from} → {to} · {rows.length} مستند</span>
          <span className="spacer" />
          {manual && canWrite && <button className="btn" onClick={() => { setEditor({ id: null }); setMsg(null); }}><Plus size={14} /> New</button>}
          {canImport && importModule && <TemplateButton module={importModule as ImportModule} />}
          {canImport && importModule && <Link className="btn secondary" href={`/import-export?module=${importModule}`}><FileUp size={14} /> Import from file</Link>}
          <button className="btn secondary" onClick={() => downloadCsv(`${docType.toLowerCase()}-${ymd(new Date())}.csv`,
            ['Doc No', 'Date', 'Status', 'Lines', 'Note', 'Override reason'],
            rows.map((r) => [r.doc_no, r.doc_date, r.status, r.document_lines?.[0]?.count ?? 0, r.note, r.override_reason]))}>
            <Download size={14} /> CSV
          </button>
        </div>
        {msg && <div className={`alert ${msg.kind}`} style={{ margin: 12 }} dir="auto">{msg.text}</div>}
        {rev && (
          <div className="toolbar" style={{ background: 'var(--warn-soft)' }}>
            <span dir="auto">Reverse <b>{rev.doc_no}</b> — السبب:</span>
            <input type="text" value={reason} onChange={(e) => setReason(e.target.value)} dir="auto" style={{ width: 280 }} autoFocus />
            <button className="btn small" disabled={!reason.trim()} onClick={reverse}>Confirm</button>
            <button className="btn secondary small" onClick={() => { setRev(null); setReason(''); }}>Cancel</button>
          </div>
        )}
        <div className="table-wrap">
          <table className="grid">
            <thead><tr><th style={{ width: 28 }} /><th>Doc No</th><th>Date</th><th>Status</th><th className="num">Lines</th><th>Note</th><th /></tr></thead>
            <tbody>
              {rows.map((r) => (
                <Fragment key={r.id}>
                  <tr>
                    <td><button className="icon-btn" style={{ color: 'var(--muted)' }} onClick={() => setOpen(open === r.id ? null : r.id)}>
                      {open === r.id ? <ChevronDown size={14} /> : <ChevronRight size={14} />}</button></td>
                    <td className="mono">{r.doc_no}</td>
                    <td>{r.doc_date}</td>
                    <td>
                      <span className={`badge ${STATUS_CLASS[r.status] ?? ''}`}>{r.status}</span>
                      {r.reverses_document_id && <span className="badge" style={{ marginLeft: 4 }}>reversal</span>}
                      {r.override_reason && <span className="badge warn" style={{ marginLeft: 4 }} title={r.override_reason}>period override</span>}
                    </td>
                    <td className="num">{r.document_lines?.[0]?.count ?? 0}</td>
                    <td dir="auto" className="muted">{r.note}</td>
                    <td style={{ whiteSpace: 'nowrap' }}>
                      {manual && canWrite && r.status === 'DRAFT' && (
                        <button className="btn secondary small" onClick={() => { setEditor({ id: r.id }); setMsg(null); }}><Pencil size={12} /> Edit</button>
                      )}{' '}
                      {canReverse && r.status === 'POSTED' && !r.reverses_document_id && (
                        <button className="btn danger small" onClick={() => { setRev(r); setMsg(null); }}><Undo2 size={13} /> Reverse</button>
                      )}
                    </td>
                  </tr>
                  {open === r.id && <tr><td colSpan={7} style={{ background: '#fafbfd', padding: 8 }}><DocumentLines docId={r.id} /></td></tr>}
                </Fragment>
              ))}
              {!rows.length && <tr><td colSpan={7} className="empty">{loading ? 'Loading…' : 'No documents in this period'}</td></tr>}
            </tbody>
          </table>
        </div>
      </div>
    </>
  );
}

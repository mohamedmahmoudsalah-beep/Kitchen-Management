'use client';
import { useEffect, useMemo, useState } from 'react';
import { Download } from 'lucide-react';
import { createClient } from '@/lib/supabase/client';
import { useScope } from '@/components/ScopeProvider';
import { downloadCsv, ymd } from '@/lib/export';
import { MODULES, type ImportModule } from '@/lib/import/columns';
import type { ImportErrorRow } from '@/lib/types';

const PAGE = 100;
const nextDay = (d: string) => { const x = new Date(d + 'T00:00:00'); x.setDate(x.getDate() + 1); return ymd(x); };

export default function ImportErrorsView() {
  const supabase = useMemo(() => createClient(), []);
  const { kitchenId, kitchen, from, to } = useScope();
  const [rows, setRows] = useState<ImportErrorRow[]>([]);
  const [count, setCount] = useState(0);
  const [page, setPage] = useState(0);
  const [err, setErr] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => { setPage(0); }, [kitchenId, from, to]);

  useEffect(() => {
    let alive = true;
    setLoading(true);
    supabase.from('import_errors')
      .select('id,batch_id,module,kitchen_id,row_no,column_name,reason,raw,created_at', { count: 'exact' })
      .or(`kitchen_id.eq.${kitchenId},kitchen_id.is.null`)
      .gte('created_at', from).lt('created_at', nextDay(to))
      .order('created_at', { ascending: false }).order('row_no')
      .range(page * PAGE, page * PAGE + PAGE - 1)
      .then(({ data, count: c, error }) => {
        if (!alive) return;
        if (error) setErr(error.message); else { setErr(null); setRows((data ?? []) as ImportErrorRow[]); setCount(c ?? 0); }
        setLoading(false);
      });
    return () => { alive = false; };
  }, [supabase, kitchenId, from, to, page]);

  async function exportAll() {
    const all: ImportErrorRow[] = [];
    for (let f = 0; ; f += 1000) {
      const { data, error } = await supabase.from('import_errors')
        .select('id,batch_id,module,kitchen_id,row_no,column_name,reason,raw,created_at')
        .or(`kitchen_id.eq.${kitchenId},kitchen_id.is.null`)
        .gte('created_at', from).lt('created_at', nextDay(to))
        .order('created_at', { ascending: false }).order('row_no').range(f, f + 999);
      if (error) { setErr(error.message); return; }
      all.push(...((data ?? []) as ImportErrorRow[]));
      if (!data || data.length < 1000) break;
    }
    downloadCsv(`import-errors-${ymd(new Date())}.csv`, ['When', 'Module', 'Batch', 'Row', 'Column', 'Reason', 'Raw'],
      all.map((e) => [e.created_at, e.module, e.batch_id, e.row_no, e.column_name, e.reason, JSON.stringify(e.raw ?? {})]));
  }

  const pages = Math.max(1, Math.ceil(count / PAGE));
  return (
    <div className="panel flush">
      <div className="toolbar">
        <span className="muted" dir="auto">أخطاء الرفع لـ {kitchen?.name} (+ Data Product) بين {from} و {to} — {count.toLocaleString()} خطأ</span>
        <span className="spacer" />
        <button className="btn secondary" onClick={exportAll}><Download size={14} /> CSV</button>
      </div>
      {err && <div className="alert err" style={{ margin: 12 }}>{err}</div>}
      <div className="table-wrap">
        <table className="grid">
          <thead><tr><th>When</th><th>Module</th><th className="num">Row</th><th>Column</th><th>Reason</th><th>Raw row</th></tr></thead>
          <tbody>
            {rows.map((e) => (
              <tr key={e.id}>
                <td className="mono" style={{ whiteSpace: 'nowrap' }}>{new Date(e.created_at).toLocaleString()}</td>
                <td>{MODULES[e.module as ImportModule]?.label ?? e.module}</td>
                <td className="num">{e.row_no === 0 ? 'File' : e.row_no}</td>
                <td>{e.column_name ?? ''}</td>
                <td dir="auto">{e.reason}</td>
                <td className="mono muted" style={{ maxWidth: 280, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{e.raw ? JSON.stringify(e.raw) : ''}</td>
              </tr>
            ))}
            {!rows.length && <tr><td colSpan={6} className="empty">{loading ? 'Loading…' : 'No import errors in this period'}</td></tr>}
          </tbody>
        </table>
      </div>
      <div className="pager">
        <button className="btn secondary small" disabled={page === 0} onClick={() => setPage((p) => p - 1)}>Previous</button>
        <span className="muted">Page {page + 1} of {pages}</span>
        <button className="btn secondary small" disabled={page + 1 >= pages} onClick={() => setPage((p) => p + 1)}>Next</button>
      </div>
    </div>
  );
}

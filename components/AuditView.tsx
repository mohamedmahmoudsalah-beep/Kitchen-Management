'use client';
import { useEffect, useMemo, useState } from 'react';
import { Download } from 'lucide-react';
import { createClient } from '@/lib/supabase/client';
import { useScope } from '@/components/ScopeProvider';
import { downloadCsv, ymd } from '@/lib/export';
import type { AuditRow } from '@/lib/types';

const PAGE = 100;
const TABLES = ['products', 'documents', 'periods', 'profiles', 'user_kitchens', 'user_pages', 'access_invites', 'kitchens'];
const nextDay = (d: string) => { const x = new Date(d + 'T00:00:00'); x.setDate(x.getDate() + 1); return ymd(x); };

function summary(r: AuditRow): string {
  if (r.action === 'UPDATE' && r.old_data && r.new_data) {
    const keys = Object.keys(r.new_data).filter((k) => k !== 'updated_at' && JSON.stringify(r.old_data![k]) !== JSON.stringify(r.new_data![k]));
    return keys.map((k) => `${k}: ${JSON.stringify(r.old_data![k])} → ${JSON.stringify(r.new_data![k])}`).join(' | ');
  }
  const d = r.new_data ?? r.old_data ?? {};
  const pick = ['doc_no', 'doc_type', 'status', 'syt_code', 'name', 'email', 'role', 'is_active', 'kitchen_id', 'page_key'].filter((k) => k in d);
  return pick.map((k) => `${k}: ${JSON.stringify(d[k])}`).join(' | ');
}

export default function AuditView() {
  const supabase = useMemo(() => createClient(), []);
  const { kitchenId, kitchen, from, to } = useScope();
  const [table, setTable] = useState('');
  const [rows, setRows] = useState<AuditRow[]>([]);
  const [count, setCount] = useState(0);
  const [page, setPage] = useState(0);
  const [err, setErr] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => { setPage(0); }, [kitchenId, from, to, table]);

  const build = (f: number, t: number, withCount: boolean) => {
    let q = supabase.from('audit_log')
      .select('id,at,user_email,table_name,row_id,action,kitchen_id,old_data,new_data', withCount ? { count: 'exact' } : undefined)
      .or(`kitchen_id.eq.${kitchenId},kitchen_id.is.null`)
      .gte('at', from).lt('at', nextDay(to))
      .order('id', { ascending: false }).range(f, t);
    if (table) q = q.eq('table_name', table);
    return q;
  };

  useEffect(() => {
    let alive = true;
    setLoading(true);
    build(page * PAGE, page * PAGE + PAGE - 1, true).then(({ data, count: c, error }) => {
      if (!alive) return;
      if (error) setErr(error.message); else { setErr(null); setRows((data ?? []) as unknown as AuditRow[]); setCount(c ?? 0); }
      setLoading(false);
    });
    return () => { alive = false; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [supabase, kitchenId, from, to, table, page]);

  async function exportAll() {
    const all: AuditRow[] = [];
    for (let f = 0; ; f += 1000) {
      const { data, error } = await build(f, f + 999, false);
      if (error) { setErr(error.message); return; }
      all.push(...((data ?? []) as unknown as AuditRow[]));
      if (!data || data.length < 1000) break;
    }
    downloadCsv(`audit-log-${ymd(new Date())}.csv`, ['When', 'User', 'Table', 'Action', 'Row', 'Details'],
      all.map((r) => [r.at, r.user_email, r.table_name, r.action, r.row_id, summary(r)]));
  }

  const pages = Math.max(1, Math.ceil(count / PAGE));
  return (
    <div className="panel flush">
      <div className="toolbar">
        <label className="muted">Table{' '}
          <select value={table} onChange={(e) => setTable(e.target.value)}>
            <option value="">All</option>{TABLES.map((t) => <option key={t} value={t}>{t}</option>)}
          </select>
        </label>
        <span className="muted" dir="auto">{kitchen?.name} + سجلات عامة · {count.toLocaleString()} سجل</span>
        <span className="spacer" />
        <button className="btn secondary" onClick={exportAll}><Download size={14} /> CSV</button>
      </div>
      {err && <div className="alert err" style={{ margin: 12 }}>{err}</div>}
      <div className="table-wrap">
        <table className="grid">
          <thead><tr><th>When</th><th>User</th><th>Table</th><th>Action</th><th>Details</th></tr></thead>
          <tbody>
            {rows.map((r) => (
              <tr key={r.id}>
                <td className="mono" style={{ whiteSpace: 'nowrap' }}>{new Date(r.at).toLocaleString()}</td>
                <td>{r.user_email ?? <span className="muted">system</span>}</td>
                <td>{r.table_name}</td>
                <td><span className={`badge ${r.action === 'DELETE' ? 'err' : r.action === 'INSERT' ? 'ok' : 'warn'}`}>{r.action}</span></td>
                <td className="mono" dir="auto" style={{ maxWidth: 520, wordBreak: 'break-word' }}>{summary(r)}</td>
              </tr>
            ))}
            {!rows.length && <tr><td colSpan={5} className="empty">{loading ? 'Loading…' : 'No audit entries'}</td></tr>}
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

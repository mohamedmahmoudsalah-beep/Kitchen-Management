'use client';
import { useEffect, useMemo, useState } from 'react';
import { createClient } from '@/lib/supabase/client';
import { useScope } from '@/components/ScopeProvider';

type Doc = { doc_no: string; doc_type: string; doc_date: string; status: string };

export default function DashboardView() {
  const supabase = useMemo(() => createClient(), []);
  const { kitchenId, kitchen, from, to } = useScope();
  const [stats, setStats] = useState({ products: 0, docs: 0, inStock: 0 });
  const [latest, setLatest] = useState<Doc[]>([]);

  useEffect(() => {
    let alive = true;
    (async () => {
      const [p, d, s, l] = await Promise.all([
        supabase.from('products').select('id', { count: 'exact', head: true }),
        supabase.from('documents').select('id', { count: 'exact', head: true }).eq('kitchen_id', kitchenId).eq('status', 'POSTED').gte('doc_date', from).lte('doc_date', to),
        supabase.from('stock_balances').select('product_id', { count: 'exact', head: true }).eq('kitchen_id', kitchenId).gt('qty_base', 0),
        supabase.from('documents').select('doc_no,doc_type,doc_date,status').eq('kitchen_id', kitchenId).order('created_at', { ascending: false }).limit(8),
      ]);
      if (!alive) return;
      setStats({ products: p.count ?? 0, docs: d.count ?? 0, inStock: s.count ?? 0 });
      setLatest((l.data ?? []) as Doc[]);
    })();
    return () => { alive = false; };
  }, [supabase, kitchenId, from, to]);

  return (
    <>
      <div className="cards">
        <div className="card"><div className="k">Products in Data Product</div><div className="v">{stats.products.toLocaleString()}</div></div>
        <div className="card"><div className="k">Products in stock · {kitchen?.name}</div><div className="v">{stats.inStock.toLocaleString()}</div></div>
        <div className="card"><div className="k">Posted documents ({from} → {to})</div><div className="v">{stats.docs.toLocaleString()}</div></div>
      </div>
      <div className="panel flush">
        <div className="toolbar"><b>Latest documents · {kitchen?.name}</b></div>
        <table className="grid">
          <thead><tr><th>Doc No</th><th>Type</th><th>Date</th><th>Status</th></tr></thead>
          <tbody>
            {latest.map((d) => (
              <tr key={d.doc_no}><td className="mono">{d.doc_no}</td><td>{d.doc_type}</td><td>{d.doc_date}</td>
                <td><span className={`badge ${d.status === 'POSTED' ? 'ok' : d.status === 'REVERSED' ? 'err' : ''}`}>{d.status}</span></td></tr>
            ))}
            {!latest.length && <tr><td colSpan={4} className="empty">No documents yet</td></tr>}
          </tbody>
        </table>
      </div>
    </>
  );
}

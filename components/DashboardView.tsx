'use client';
import { useEffect, useMemo, useState } from 'react';
import Link from 'next/link';
import { AlertTriangle } from 'lucide-react';
import { createClient } from '@/lib/supabase/client';
import { useScope } from '@/components/ScopeProvider';
import { fmt, toPieces } from '@/lib/qty';

type Summary = {
  stock_value: number; products_in_stock: number; in_transit_value: number; return_pending_value: number;
  incoming_to_confirm: number; outgoing_pending: number; returns_to_confirm: number; drafts: number;
  last_closing: string | null; locked_through: string | null; cost_warnings: number; pending_users: number | null;
  top_products: { syt_code: string; product_name: string; qty: number; uom_factor: number; value: number }[];
};

const daysAgo = (d: string) => Math.floor((Date.now() - new Date(d + 'T00:00:00').getTime()) / 86400000);

export default function DashboardView({ pages }: { pages: string[] }) {
  const supabase = useMemo(() => createClient(), []);
  const { kitchenId, kitchen } = useScope();
  const [s, setS] = useState<Summary | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const has = (k: string) => pages.includes(k);

  useEffect(() => {
    let alive = true;
    setS(null); setErr(null);
    supabase.rpc('dashboard_summary', { p_kitchen: kitchenId }).then(({ data, error }) => {
      if (!alive) return;
      if (error) setErr(error.message); else setS(data as Summary);
    });
    return () => { alive = false; };
  }, [supabase, kitchenId]);

  if (err) return <div className="alert err" dir="auto">{err}</div>;
  if (!s) return <div className="muted">Loading…</div>;

  const attention: { text: string; href?: string }[] = [];
  if (s.incoming_to_confirm > 0) attention.push({ text: `${s.incoming_to_confirm} تحويل واصل ومستني تأكيد الاستلام`, href: has('kitchens_transfer') ? '/kitchens-transfer' : undefined });
  if (s.returns_to_confirm > 0) attention.push({ text: `${s.returns_to_confirm} تحويل فيه مرتجع معلق لازم تأكد رجوعه (أو تنزّله Missing)`, href: has('kitchens_transfer') ? '/kitchens-transfer' : undefined });
  if (s.outgoing_pending > 0) attention.push({ text: `${s.outgoing_pending} تحويل مبعوت لسه ما اتستلمش`, href: has('kitchens_transfer') ? '/kitchens-transfer' : undefined });
  if (s.drafts > 0) attention.push({ text: `${s.drafts} مستند Draft لسه ما اتعملوش Post` });
  if (!s.last_closing) attention.push({ text: 'مفيش جرد (Closing) متسجل للمطبخ ده', href: has('closing_stock_count') ? '/closing-stock-count' : undefined });
  else if (daysAgo(s.last_closing) > 35) attention.push({ text: `آخر جرد كان من ${daysAgo(s.last_closing)} يوم (${s.last_closing})`, href: has('closing_stock_count') ? '/closing-stock-count' : undefined });
  if (s.cost_warnings > 0) attention.push({ text: `${s.cost_warnings} منتج تكلفته مش متسقة مع Base Qty × Cost Pr UOM`, href: has('data_product') ? '/data-product' : undefined });
  if (s.pending_users) attention.push({ text: `${s.pending_users} مستخدم مستني تفعيل`, href: '/access-control' });

  return (
    <>
      <div className="cards">
        <div className="card"><div className="k">Stock value · {kitchen?.name}</div><div className="v">{fmt(s.stock_value, 0)}</div>
          <div className="muted">{s.products_in_stock.toLocaleString()} products in stock · @ current cost</div></div>
        <div className="card"><div className="k">In transit (from here)</div><div className="v">{fmt(s.in_transit_value, 0)}</div>
          <div className="muted">{s.outgoing_pending} transfers waiting</div></div>
        <div className="card"><div className="k">Return pending</div><div className="v">{fmt(s.return_pending_value, 0)}</div>
          <div className="muted">{s.returns_to_confirm} transfers</div></div>
        <div className="card"><div className="k">Last count</div><div className="v" style={{ fontSize: '1.2rem' }}>{s.last_closing ?? '—'}</div>
          <div className="muted">{s.locked_through ? `Locked through ${s.locked_through}` : 'No locked period'}</div></div>
      </div>

      <div className="panel">
        <h2>Needs attention</h2>
        {attention.length === 0 ? <div className="muted">كله تمام ✓</div> : (
          <div style={{ display: 'grid', gap: 6 }}>
            {attention.map((a, i) => (
              <div key={i} dir="auto" style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
                <AlertTriangle size={14} color="var(--warn)" />
                {a.href ? <Link href={a.href}>{a.text}</Link> : <span>{a.text}</span>}
              </div>
            ))}
          </div>
        )}
      </div>

      <div className="panel flush">
        <div className="toolbar"><b>Top stock by value · {kitchen?.name}</b></div>
        <table className="grid">
          <thead><tr><th>Syt Code</th><th>Product</th><th className="num">Qty (base)</th><th className="num">Syt pcs</th><th className="num">Value</th></tr></thead>
          <tbody>
            {s.top_products.map((p) => (
              <tr key={p.syt_code}>
                <td className="mono">{p.syt_code}</td><td dir="auto">{p.product_name}</td>
                <td className="num">{fmt(p.qty)}</td>
                <td className="num">{Number(p.uom_factor) !== 1 ? fmt(toPieces(Number(p.qty), Number(p.uom_factor))) : '—'}</td>
                <td className="num">{fmt(p.value, 2)}</td>
              </tr>
            ))}
            {!s.top_products.length && <tr><td colSpan={5} className="empty">No stock yet — import the opening balance</td></tr>}
          </tbody>
        </table>
      </div>
    </>
  );
}

'use client';
import { useEffect, useMemo, useState } from 'react';
import Link from 'next/link';
import { AlertTriangle, RefreshCw } from 'lucide-react';
import { createClient } from '@/lib/supabase/client';
import { useScope } from '@/components/ScopeProvider';
import { BarList, LineChart } from '@/components/Charts';
import { invalidateAll, loadCached } from '@/lib/cache';
import { fmt, toPieces } from '@/lib/qty';

type Summary = {
  kitchens_count: number; stock_value: number; products_in_stock: number; in_transit_value: number; return_pending_value: number;
  incoming_to_confirm: number; outgoing_pending: number; returns_to_confirm: number; drafts: number;
  last_closing: string | null; kitchens_without_closing: number; locked_through: string | null; cost_warnings: number; pending_users: number | null;
  low_stock: { low: number; avg: number; high: number; not_set: number } | null;
  top_products: { syt_code: string; product_name: string; qty: number; uom_factor: number; value: number }[];
  by_category: { category: string; value: number }[];
  by_kitchen: { name: string; value: number }[];
};
type Day = { day: string; stock_value: number; usage_value: number; waste_value: number; purchases_value: number };

const daysAgo = (d: string) => Math.floor((Date.now() - new Date(d + 'T00:00:00').getTime()) / 86400000);
const addDays = (d: string, n: number) => { const x = new Date(d + 'T00:00:00Z'); x.setUTCDate(x.getUTCDate() + n); return x.toISOString().slice(0, 10); };
const money = (v: number) => fmt(v, 0);

export default function DashboardView({ pages }: { pages: string[] }) {
  const supabase = useMemo(() => createClient(), []);
  const { kitchens, kitchenId, kitchen, dashAll, from, to } = useScope();
  const all = dashAll && kitchens.length > 1;
  const kid = all ? null : kitchenId;
  const scopeName = all ? 'All kitchens' : kitchen?.name;
  const [s, setS] = useState<Summary | null>(null);
  const [days, setDays] = useState<Day[] | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [trendErr, setTrendErr] = useState<string | null>(null);
  const [nonce, setNonce] = useState(0);   // زرار Refresh
  const has = (k: string) => pages.includes(k);

  // الرسم بيغطي آخر 180 يوم كحد أقصى من تاريخ "To"
  const clamped = to > from && new Date(to).getTime() - new Date(from).getTime() > 179 * 86400000;
  const trendFrom = clamped ? addDays(to, -179) : from;

  useEffect(() => {
    let alive = true;
    setS(null); setErr(null);
    loadCached<Summary>(`dash:${kid ?? 'ALL'}`, async () => {
      const { data, error } = await supabase.rpc('dashboard_summary', { p_kitchen: kid });
      if (error) throw new Error(error.message);
      return data as Summary;
    }, (d) => { if (alive) setS(d); }).catch((e: Error) => { if (alive) setErr(e.message); });
    return () => { alive = false; };
  }, [supabase, kid, nonce]);

  useEffect(() => {
    let alive = true;
    setDays(null); setTrendErr(null);
    loadCached<Day[]>(`trend:${kid ?? 'ALL'}:${trendFrom}:${to}`, async () => {
      const { data, error } = await supabase.rpc('dashboard_trend', { p_kitchen: kid, p_from: trendFrom, p_to: to });
      if (error) throw new Error(error.message);
      return ((data ?? []) as Day[]).map((d) => ({ ...d, stock_value: Number(d.stock_value), usage_value: Number(d.usage_value), waste_value: Number(d.waste_value), purchases_value: Number(d.purchases_value) }));
    }, (d) => { if (alive) setDays(d); }).catch((e: Error) => { if (alive) setTrendErr(e.message); });
    return () => { alive = false; };
  }, [supabase, kid, trendFrom, to, nonce]);

  const totals = useMemo(() => {
    const d = days ?? [];
    const sum = (k: 'usage_value' | 'waste_value' | 'purchases_value') => d.reduce((a, r) => a + r[k], 0);
    return { usage: sum('usage_value'), waste: sum('waste_value'), purchases: sum('purchases_value') };
  }, [days]);

  if (err) return <div className="alert err" dir="auto">{err}</div>;
  if (!s) return <div className="muted">Loading…</div>;

  const link = (key: string, href: string) => (has(key) ? href : undefined);
  const attention: { text: string; href?: string }[] = [];
  if (s.incoming_to_confirm > 0) attention.push({ text: `${s.incoming_to_confirm} تحويل واصل ومستني تأكيد الاستلام`, href: link('kitchens_transfer', '/kitchens-transfer') });
  if (s.returns_to_confirm > 0) attention.push({ text: `${s.returns_to_confirm} تحويل فيه مرتجع معلق لازم تأكد رجوعه (أو تنزّله Missing)`, href: link('kitchens_transfer', '/kitchens-transfer') });
  if (s.outgoing_pending > 0) attention.push({ text: `${s.outgoing_pending} تحويل مبعوت لسه ما اتستلمش`, href: link('kitchens_transfer', '/kitchens-transfer') });
  if (s.drafts > 0) attention.push({ text: `${s.drafts} مستند Draft لسه ما اتعملوش Post` });
  if (all) {
    if (s.kitchens_without_closing > 0) attention.push({ text: `${s.kitchens_without_closing} مطبخ من ${s.kitchens_count} مفيش له جرد (Closing) متسجل`, href: link('closing_stock_count', '/closing-stock-count') });
  } else if (!s.last_closing) attention.push({ text: 'مفيش جرد (Closing) متسجل للمطبخ ده', href: link('closing_stock_count', '/closing-stock-count') });
  else if (daysAgo(s.last_closing) > 35) attention.push({ text: `آخر جرد كان من ${daysAgo(s.last_closing)} يوم (${s.last_closing})`, href: link('closing_stock_count', '/closing-stock-count') });
  if (s.low_stock && s.low_stock.low > 0) attention.push({ text: `${s.low_stock.low} صنف Low stock`, href: link('low_stock', '/low-stock') });
  if (s.cost_warnings > 0) attention.push({ text: `${s.cost_warnings} منتج تكلفته مش متسقة مع Base Qty × Cost Pr UOM`, href: link('data_product', '/data-product') });
  if (s.pending_users) attention.push({ text: `${s.pending_users} مستخدم مستني تفعيل`, href: '/access-control' });

  const labels = (days ?? []).map((d) => d.day);
  const period = `${trendFrom} → ${to}`;

  return (
    <>
      <div style={{ display: 'flex', justifyContent: 'flex-end' }}>
        <button className="btn secondary small" title="تحديث البيانات (بيتخزّن لمدة قصيرة عشان الصفحة تفتح أسرع)" onClick={() => { invalidateAll(); setNonce((n) => n + 1); }}><RefreshCw size={13} /> Refresh</button>
      </div>
      <div className="cards">
        <div className="card"><div className="k">Stock value · {scopeName}</div><div className="v">{money(s.stock_value)}</div>
          <div className="muted">{s.products_in_stock.toLocaleString()} products in stock · @ current cost</div></div>
        <div className="card"><div className="k">Purchases · period</div><div className="v">{days ? money(totals.purchases) : '…'}</div><div className="muted">{period}</div></div>
        <div className="card"><div className="k">Usage (warehouse issues) · period</div><div className="v">{days ? money(totals.usage) : '…'}</div><div className="muted">{period}</div></div>
        <div className="card"><div className="k">Waste · period</div><div className="v">{days ? money(totals.waste) : '…'}</div><div className="muted">{period}</div></div>
        <div className="card"><div className="k">In transit (from here)</div><div className="v">{money(s.in_transit_value)}</div>
          <div className="muted">{s.outgoing_pending} transfers waiting</div></div>
        <div className="card"><div className="k">Return pending</div><div className="v">{money(s.return_pending_value)}</div>
          <div className="muted">{s.returns_to_confirm} transfers</div></div>
        <div className="card"><div className="k">Last count</div><div className="v" style={{ fontSize: '1.2rem' }}>{s.last_closing ?? '—'}</div>
          <div className="muted">{s.locked_through ? `Locked through ${s.locked_through}` : 'No locked period'}</div></div>
      </div>

      {s.low_stock && (
        <div className="cards">
          {([['low', 'Low stock', 'err'], ['avg', 'Avg stock', 'warn'], ['high', 'High stock', 'ok'], ['not_set', 'Not set', '']] as const).map(([k, label, cls]) => {
            const body = (<><div className="k"><span className={`badge ${cls}`}>{label}</span></div><div className="v">{s.low_stock![k].toLocaleString()}</div><div className="muted">items · live stock</div></>);
            return has('low_stock') ? <Link key={k} href="/low-stock" className="card clickable">{body}</Link> : <div key={k} className="card">{body}</div>;
          })}
        </div>
      )}

      {trendErr && <div className="alert err" dir="auto">{trendErr}</div>}
      {clamped && <div className="muted" dir="auto">الرسومات بتغطي آخر 180 يوم بس ({trendFrom} → {to}).</div>}

      <div className="dash-grid">
        <div className="panel">
          <h2>Stock value by day</h2>
          <div className="sub">قيمة المخزون آخر كل يوم · {scopeName} · @ current cost</div>
          {!days ? <div className="muted">Loading…</div> : <LineChart area labels={labels} series={[{ name: 'Stock value', color: '#d4146f', values: days.map((d) => d.stock_value) }]} />}
        </div>
        <div className="panel">
          <h2>Daily usage &amp; waste</h2>
          <div className="sub" dir="auto">الاستهلاك اليومي = صرف المخزن (Warehouse Transactions). الاستهلاك الفعلي بعد الجرد بتلاقيه في صفحة Consumption.</div>
          {!days ? <div className="muted">Loading…</div> : <LineChart labels={labels} series={[
            { name: 'Usage', color: '#1f2858', values: days.map((d) => d.usage_value) },
            { name: 'Waste', color: '#c62135', values: days.map((d) => d.waste_value) }]} />}
        </div>
        <div className="panel">
          <h2>Purchases by day</h2>
          <div className="sub">قيمة المشتريات اليومية · @ current cost</div>
          {!days ? <div className="muted">Loading…</div> : <LineChart area labels={labels} series={[{ name: 'Purchases', color: '#138a52', values: days.map((d) => d.purchases_value) }]} />}
        </div>
        <div className="panel">
          <h2>{all ? 'Stock value by kitchen' : 'Stock value by category'}</h2>
          <div className="sub">{all ? 'كل مطبخ وقيمة مخزونه الحالية' : 'أعلى 8 فئات بالقيمة'}</div>
          <BarList items={(all ? s.by_kitchen.map((k) => ({ label: k.name, value: Number(k.value) })) : s.by_category.map((c) => ({ label: c.category, value: Number(c.value) })))} />
        </div>
        {all && (
          <div className="panel">
            <h2>Stock value by category</h2>
            <div className="sub">أعلى 8 فئات بالقيمة · كل المطابخ</div>
            <BarList color="#1f2858" items={s.by_category.map((c) => ({ label: c.category, value: Number(c.value) }))} />
          </div>
        )}
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
      </div>

      <div className="panel flush">
        <div className="toolbar"><b>Top stock by value · {scopeName}</b></div>
        <table className="grid">
          <thead><tr><th>Syt Code</th><th>Product</th><th className="num">Qty (base)</th><th className="num">Syt pcs</th><th className="num">Value</th></tr></thead>
          <tbody>
            {s.top_products.map((p) => (
              <tr key={p.syt_code}>
                <td className="mono">{p.syt_code}</td><td dir="auto">{p.product_name}</td>
                <td className="num">{fmt(p.qty)}</td>
                <td className="num">{!all && Number(p.uom_factor) !== 1 ? fmt(toPieces(Number(p.qty), Number(p.uom_factor))) : '—'}</td>
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

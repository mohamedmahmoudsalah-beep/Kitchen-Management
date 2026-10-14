'use client';
import Link from 'next/link';
import { usePathname, useRouter } from 'next/navigation';
import { useCallback, useEffect, useMemo, useState } from 'react';
import {
  LayoutDashboard, PackageOpen, ShoppingCart, ArrowLeftRight, Warehouse, Trash2, ClipboardCheck,
  Flame, Boxes, SlidersHorizontal, Database, FileUp, FileWarning, ShieldCheck, ScrollText,
  Search, PanelLeftClose, PanelLeftOpen, LogOut, TrendingDown,
} from 'lucide-react';
import type { Kitchen, PageDef } from '@/lib/types';
import { GLOBAL_PAGES, NAV_GROUPS, NO_DATE_PAGES, PAGE_HREF } from '@/lib/nav';
import { ScopeProvider, useScope } from '@/components/ScopeProvider';
import { createClient } from '@/lib/supabase/client';
import Logo from '@/components/Logo';

const ICONS: Record<string, React.ComponentType<{ size?: number }>> = {
  dashboard: LayoutDashboard, opening_balance: PackageOpen, purchases: ShoppingCart, kitchens_transfer: ArrowLeftRight,
  warehouse_transactions: Warehouse, waste: Trash2, closing_stock_count: ClipboardCheck, consumption: Flame,
  warehouse_stock: Boxes, low_stock: TrendingDown, stock_adjustments: SlidersHorizontal, data_product: Database, import_export: FileUp,
  import_errors: FileWarning, access_control: ShieldCheck, audit_log: ScrollText,
};

function keyOfPath(path: string): string | undefined {
  if (path === '/') return 'dashboard';
  return Object.entries(PAGE_HREF).find(([, href]) => href !== '/' && (path === href || path.startsWith(href + '/')))?.[0];
}

function Sidebar({ pages, email }: { pages: PageDef[]; email: string }) {
  const path = usePathname();
  const router = useRouter();
  const [q, setQ] = useState('');
  const [collapsed, setCollapsed] = useState(false);
  const activeKey = keyOfPath(path);
  const byKey = useMemo(() => new Map(pages.map((p) => [p.key, p])), [pages]);
  const needle = q.trim().toLowerCase();

  // عدّاد التحويلات: واردة مستنية تأكيد استلام + مرتجعات معلّقة لازم المرسل يأكدها
  const { kitchens } = useScope();
  const hasTransfers = byKey.has('kitchens_transfer');
  const [pending, setPending] = useState({ incoming: 0, returns: 0 });
  const refreshPending = useCallback(async () => {
    if (!hasTransfers || !kitchens.length) return;
    const sb = createClient();
    const ids = kitchens.map((k) => k.id);
    const [inc, ret] = await Promise.all([
      sb.from('documents').select('id', { count: 'exact', head: true }).eq('doc_type', 'TRANSFER').eq('status', 'PENDING_RECEIPT').in('counterpart_kitchen_id', ids),
      sb.from('documents').select('id', { count: 'exact', head: true }).eq('doc_type', 'TRANSFER').eq('status', 'RETURN_PENDING').in('kitchen_id', ids),
    ]);
    setPending({ incoming: inc.count ?? 0, returns: ret.count ?? 0 });
  }, [hasTransfers, kitchens]);
  useEffect(() => {
    refreshPending();
    const t = setInterval(refreshPending, 60000);
    window.addEventListener('focus', refreshPending);
    window.addEventListener('kms:transfers-changed', refreshPending);
    return () => { clearInterval(t); window.removeEventListener('focus', refreshPending); window.removeEventListener('kms:transfers-changed', refreshPending); };
  }, [refreshPending, path]);
  const pendingTotal = pending.incoming + pending.returns;

  return (
    <aside className={`sidebar ${collapsed ? 'collapsed' : ''}`}>
      <div className="brand">
        <Logo size={30} />
        <span className="label">Kitchens</span>
        <button className="icon-btn" style={{ marginLeft: 'auto' }} onClick={() => setCollapsed((c) => !c)} title="Toggle sidebar">
          {collapsed ? <PanelLeftOpen size={16} /> : <PanelLeftClose size={16} />}
        </button>
      </div>
      <div className="search">
        <Search size={14} />
        <input value={q} onChange={(e) => setQ(e.target.value)} placeholder="Search page" aria-label="Search page" />
      </div>
      <nav className="nav">
        {NAV_GROUPS.map((g) => {
          const items = g.keys.map((k) => byKey.get(k)).filter((p): p is PageDef => !!p && (!needle || p.title.toLowerCase().includes(needle)));
          if (!items.length) return null;
          return (
            <div key={g.title}>
              <div className="nav-title">{g.title}</div>
              {items.map((p) => {
                const Icon = ICONS[p.key];
                return (
                  <Link key={p.key} href={PAGE_HREF[p.key]} className={`nav-item ${activeKey === p.key ? 'active' : ''}`} title={p.title}>
                    {Icon && <Icon size={16} />}<span className="label">{p.title}</span>
                    {p.key === 'kitchens_transfer' && pendingTotal > 0 && (
                      <span className="nav-badge" title={`${pending.incoming} تحويل وارد مستني استلام · ${pending.returns} مرتجع معلّق`}>{pendingTotal > 99 ? '99+' : pendingTotal}</span>
                    )}
                  </Link>
                );
              })}
            </div>
          );
        })}
      </nav>
      <div className="side-foot">
        <span className="who" title={email}>{email}</span>
        <button className="icon-btn" title="Sign out"
          onClick={async () => { await createClient().auth.signOut(); router.replace('/login'); router.refresh(); }}>
          <LogOut size={16} />
        </button>
      </div>
    </aside>
  );
}

function Topbar({ pages }: { pages: PageDef[] }) {
  const path = usePathname();
  const key = keyOfPath(path);
  const title = pages.find((p) => p.key === key)?.title ?? '';
  const { kitchens, kitchenId, setKitchenId, from, to, setFrom, setTo, dashAll, setDashAll } = useScope();
  const off = key ? GLOBAL_PAGES.has(key) : false;
  const noDates = key ? NO_DATE_PAGES.has(key) : false;
  const allOption = key === 'dashboard' && kitchens.length > 1;
  return (
    <header className="topbar">
      <h1>{title}</h1>
      <div className={`scope ${off ? 'off' : ''}`} title={off ? 'الصفحة دي مش مرتبطة بمطبخ أو فترة' : undefined}>
        <label>Branch
          <select value={allOption && dashAll ? 'ALL' : kitchenId}
            onChange={(e) => { if (e.target.value === 'ALL') setDashAll(true); else { setDashAll(false); setKitchenId(e.target.value); } }}>
            {allOption && <option value="ALL">All Kitchens</option>}
            {kitchens.map((k) => <option key={k.id} value={k.id}>{k.name}</option>)}
          </select>
        </label>
        {!noDates && <label>From <input type="date" value={from} max={to} onChange={(e) => setFrom(e.target.value)} /></label>}
        {!noDates && <label>To <input type="date" value={to} min={from} onChange={(e) => setTo(e.target.value)} /></label>}
      </div>
    </header>
  );
}

export default function Shell({ kitchens, pages, email, children }: {
  kitchens: Kitchen[]; pages: PageDef[]; email: string; children: React.ReactNode;
}) {
  return (
    <ScopeProvider kitchens={kitchens}>
      <div className="shell">
        <Sidebar pages={pages} email={email} />
        <div className="main">
          <Topbar pages={pages} />
          <main className="content">{children}</main>
        </div>
      </div>
    </ScopeProvider>
  );
}

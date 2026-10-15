import { beforeEach, describe, expect, it } from 'vitest';
import { invalidateAll, loadCached } from '@/lib/cache';
import { isWriteRpc } from '@/lib/supabase/client';
import { allowedPages } from '@/lib/auth';

let t = 0; const now = () => t;
const run = async <T,>(key: string, loader: () => Promise<T>, o: { ttl?: number; maxStale?: number } = {}) => {
  const seen: [T, boolean][] = [];
  await loadCached(key, loader, (d, c) => seen.push([d, c]), { ...o, now });
  return seen;
};

describe('loadCached (stale-while-revalidate)', () => {
  beforeEach(() => { invalidateAll(); t = 1_000_000; });

  it('first load fetches, second within ttl uses the cache without fetching', async () => {
    let calls = 0; const loader = async () => ++calls;
    expect(await run('k', loader, { ttl: 1000 })).toEqual([[1, false]]);
    t += 500;
    expect(await run('k', loader, { ttl: 1000 })).toEqual([[1, true]]);
    expect(calls).toBe(1);
  });
  it('stale entry is shown immediately, then replaced by fresh data', async () => {
    let calls = 0; const loader = async () => ++calls;
    await run('k', loader, { ttl: 1000, maxStale: 60_000 });
    t += 5000;
    expect(await run('k', loader, { ttl: 1000, maxStale: 60_000 })).toEqual([[1, true], [2, false]]);
  });
  it('too old entry is not shown at all', async () => {
    let calls = 0; const loader = async () => ++calls;
    await run('k', loader, { ttl: 1000, maxStale: 2000 });
    t += 10_000;
    expect(await run('k', loader, { ttl: 1000, maxStale: 2000 })).toEqual([[2, false]]);
  });
  it('different keys do not share data', async () => {
    await run('a', async () => 'A'); expect(await run('b', async () => 'B')).toEqual([['B', false]]);
  });
  it('invalidateAll forces a reload', async () => {
    let calls = 0; const loader = async () => ++calls;
    await run('k', loader); invalidateAll();
    expect(await run('k', loader)).toEqual([[2, false]]);
  });
  it('a write during loading means the result is not stored', async () => {
    let release!: () => void; const gate = new Promise<void>((r) => { release = r; });
    let calls = 0;
    const slow = async () => { await gate; return ++calls; };
    const p = run('k', slow);
    invalidateAll();            // كتابة حصلت والطلب لسه شغال
    release(); await p;
    expect(await run('k', async () => ++calls)).toEqual([[2, false]]);   // مفيش cache قديم
  });
  it('concurrent loads share one request', async () => {
    let calls = 0; const loader = async () => { await Promise.resolve(); return ++calls; };
    await Promise.all([run('k', loader), run('k', loader)]);
    expect(calls).toBe(1);
  });
  it('errors propagate and are not cached', async () => {
    await expect(run('k', async () => { throw new Error('boom'); })).rejects.toThrow('boom');
    expect(await run('k', async () => 'ok')).toEqual([['ok', false]]);
  });
});

describe('which rpc calls clear the cache', () => {
  it('reads keep it, writes clear it', () => {
    for (const n of ['report_consumption', 'report_warehouse_stock', 'report_low_stock', 'dashboard_summary', 'dashboard_trend', 'documents_search', 'product_card', 'last_purchased_syt', 'page_data_preview', 'purge_preview', 'import_validate', 'my_session'])
      expect(isWriteRpc(n)).toBe(false);
    for (const n of ['post_document', 'reverse_document', 'edit_document_line', 'save_document', 'import_commit', 'purge_range', 'purge_page_data', 'save_product', 'close_period', 'reset_all_data'])
      expect(isWriteRpc(n)).toBe(true);
  });
  it('low stock import: validate keeps the cache, commit clears it', () => {
    expect(isWriteRpc('stock_levels_import', { p_commit: false })).toBe(false);
    expect(isWriteRpc('stock_levels_import', { p_commit: true })).toBe(true);
  });
});

describe('allowedPages', () => {
  const pages = [{ key: 'dashboard', title: 'D', sort: 1 }, { key: 'purchases', title: 'P', sort: 2 }, { key: 'access_control', title: 'A', sort: 3 }];
  const prof = (role: string) => ({ user_id: 'u', email: 'e', full_name: null, role, is_active: true, is_root: false }) as never;
  it('admin sees everything', () => expect(allowedPages(prof('admin'), pages, []).map((p) => p.key)).toEqual(['dashboard', 'purchases', 'access_control']));
  it('manager gets granted pages + Access Control', () => expect(allowedPages(prof('manager'), pages, ['purchases']).map((p) => p.key)).toEqual(['purchases', 'access_control']));
  it('kitchen user only granted pages, never Access Control', () => expect(allowedPages(prof('kitchen_user'), pages, ['dashboard', 'access_control']).map((p) => p.key)).toEqual(['dashboard']));
});

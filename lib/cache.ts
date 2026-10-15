// Cache بسيط في المتصفح للتقارير والـ Dashboard (stale-while-revalidate):
//  - أحدث من ttl: بيتعرض ومفيش طلب
//  - أقدم من ttl لكن أحدث من maxStale: بيتعرض فورًا وبيتحدّث في الخلفية
//  - أقدم من كده: بيتحمّل عادي
// أي كتابة (Post / Reverse / Import / تعديل…) بتمسح الـ Cache كله عن طريق lib/supabase/client.ts
type Entry = { data: unknown; at: number };
const store = new Map<string, Entry>();
const inflight = new Map<string, Promise<unknown>>();
let generation = 0;

export const DEFAULT_TTL = 45_000;
export const DEFAULT_MAX_STALE = 600_000;

export function invalidateAll() { generation++; store.clear(); inflight.clear(); }
export const cacheSize = () => store.size;

export async function loadCached<T>(
  key: string, loader: () => Promise<T>, apply: (data: T, fromCache: boolean) => void,
  opts: { ttl?: number; maxStale?: number; now?: () => number } = {},
): Promise<void> {
  const { ttl = DEFAULT_TTL, maxStale = DEFAULT_MAX_STALE, now = Date.now } = opts;
  const hit = store.get(key);
  const age = hit ? now() - hit.at : Infinity;
  if (hit && age < maxStale) {
    apply(hit.data as T, true);
    if (age < ttl) return;
  }
  const gen = generation;
  let p = inflight.get(key) as Promise<T> | undefined;
  if (!p) {
    p = loader().finally(() => { if (inflight.get(key) === p) inflight.delete(key); });
    inflight.set(key, p);
  }
  const data = await p;
  if (gen === generation) store.set(key, { data, at: now() });   // لو حصلت كتابة وإحنا بنحمّل، النتيجة دي قديمة فمنخزنهاش
  apply(data, false);
}

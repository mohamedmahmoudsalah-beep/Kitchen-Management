import { createBrowserClient } from '@supabase/ssr';
import type { SupabaseClient } from '@supabase/supabase-js';
import { invalidateAll } from '@/lib/cache';

// دوال قراءة بس (مبتمسحش الـ Cache). أي RPC تاني بيتعامل معاه كأنه كتابة.
const READ_ONLY = /^(report_|dashboard_|documents_search$|product_card$|last_purchased_syt$|page_data_preview$|purge_preview$|transfer_kitchens$|my_session$)/;
export const isWriteRpc = (name: string, args?: Record<string, unknown>) =>
  !READ_ONLY.test(name) && !(name === 'import_validate') && !(name === 'stock_levels_import' && args?.p_commit === false);

type Patched = SupabaseClient & { __kmsPatched?: boolean };

export function createClient() {
  const client = createBrowserClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    (process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY ?? process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY)!,
  ) as Patched;

  if (!client.__kmsPatched) {
    client.__kmsPatched = true;
    // أي كتابة بتمسح الـ Cache (قبلها وبعد ما تخلص) عشان التقارير متفضلش على أرقام قديمة
    const rpc = client.rpc.bind(client);
    client.rpc = ((fn: string, args?: Record<string, unknown>, opts?: unknown) => {
      const write = isWriteRpc(fn, args);
      if (write) invalidateAll();
      const builder = rpc(fn, args as never, opts as never) as unknown as PromiseLike<unknown> & { then: PromiseLike<unknown>['then'] };
      if (write) {
        const then = builder.then.bind(builder);
        builder.then = ((res: never, rej: never) => then((v: unknown) => { invalidateAll(); return res ? (res as (x: unknown) => unknown)(v) : v; }, rej)) as typeof builder.then;
      }
      return builder;
    }) as typeof client.rpc;
    // تغيير المستخدم على نفس المتصفح = Cache جديد
    client.auth.onAuthStateChange((event) => { if (event === 'SIGNED_OUT' || event === 'SIGNED_IN') invalidateAll(); });
  }
  return client;
}

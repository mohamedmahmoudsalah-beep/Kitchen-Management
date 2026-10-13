// أكواد (Generic) بتطابق أكتر من حجم (Syt Code): نجيب الأحجام، ونختار آخر حجم اتشترى، والمستخدم يغيّره من غير ما يرفع الملف تاني
import type { SupabaseClient } from '@supabase/supabase-js';

export type Prod = { id: string; syt_code: string; generic_code: string | null; name: string; uom_factor: number; uom_name?: string | null; is_active: boolean };
// same = كل الأحجام المتاحة نفس الـ UOM ونفس الـ base (فمش لازم المستخدم يختار)
export type Ambig = { code: string; rowCount: number; options: Prod[]; same: boolean };
// نفس شكل الصفوف اللي بيرجّعها mapRows: { row_no, data: { code, qty, ... } }
export type Row = { row_no: number; data: Record<string, string> };

const codeOf = (r: Row) => String(r.data?.code ?? '').trim();

export function findAmbiguous(rows: Row[], products: Prod[]): Ambig[] {
  const counts = new Map<string, number>();
  rows.forEach((r) => { const c = codeOf(r); if (c) counts.set(c, (counts.get(c) ?? 0) + 1); });
  const out: Ambig[] = [];
  for (const [code, rowCount] of counts) {
    // نفس قاعدة الداتا بيز: syt_code = الكود أو generic_code = الكود
    const matches = products.filter((p) => p.syt_code === code || p.generic_code === code);
    if (matches.length > 1) {
      const options = matches.filter((p) => p.is_active).sort((a, b) => a.syt_code.localeCompare(b.syt_code));
      const sig = (p: Prod) => `${Number(p.uom_factor)}|${(p.uom_name ?? '').trim().toLowerCase()}`;
      out.push({ code, rowCount, options, same: options.length > 0 && options.every((o) => sig(o) === sig(options[0])) });
    }
  }
  return out.filter((a) => a.options.length > 0).sort((a, b) => a.code.localeCompare(b.code));
}

export function applyChoices(rows: Row[], choices: Record<string, string>): Row[] {
  return rows.map((r) => { const c = choices[codeOf(r)]; return c ? { ...r, data: { ...r.data, code: c } } : r; });
}

export async function loadProductsForCodes(sb: SupabaseClient, rows: Row[]): Promise<Prod[]> {
  const codes = [...new Set(rows.map(codeOf).filter(Boolean))];
  const byId = new Map<string, Prod>();
  const SEL = 'id,syt_code,generic_code,name,uom_factor,uom_name,is_active';
  for (let i = 0; i < codes.length; i += 150) {
    const chunk = codes.slice(i, i + 150);
    for (const col of ['syt_code', 'generic_code'] as const) {
      const { data } = await sb.from('products').select(SEL).in(col, chunk).limit(5000);
      (data ?? []).forEach((p) => byId.set((p as Prod).id, p as Prod));
    }
  }
  return [...byId.values()];
}

export async function lastPurchased(sb: SupabaseClient, codes: string[]): Promise<Record<string, { syt: string; date: string }>> {
  if (!codes.length) return {};
  const { data } = await sb.rpc('last_purchased_syt', { p_codes: codes });
  const out: Record<string, { syt: string; date: string }> = {};
  ((data ?? []) as { code: string; syt_code: string; last_date: string }[]).forEach((r) => { out[r.code] = { syt: r.syt_code, date: r.last_date }; });
  return out;
}

// الاختيار الابتدائي: آخر حجم اتشترى لو موجود، وإلا لو الأحجام متطابقة ناخد أول واحد. الباقي بيسيبه للمستخدم.
export function initialChoices(amb: Ambig[], last: Record<string, { syt: string; date: string }>): Record<string, string> {
  const out: Record<string, string> = {};
  for (const a of amb) {
    const l = last[a.code]?.syt;
    if (l && a.options.some((o) => o.syt_code === l)) out[a.code] = l;
    else if (a.same && a.options.length) out[a.code] = a.options[0].syt_code;
  }
  return out;
}

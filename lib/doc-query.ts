// قوايم المستندات: بحث + ترقيم صفحات من الداتا بيز (documents_search) — من غير حد 500
import type { SupabaseClient } from '@supabase/supabase-js';

export type DocQuery = {
  type: string; kitchenId: string; from: string; to: string;
  mode?: 'own' | 'incoming'; includeOpen?: boolean; reversals?: boolean; q?: string; status?: string;
};
export type DocRow = {
  id: string; doc_no: string; doc_type: string; doc_date: string; status: string; note: string | null; override_reason: string | null;
  reverses_document_id: string | null; created_at: string; kitchen_id: string; counterpart_kitchen_id: string | null;
  document_lines: { count: number }[];
};
type Raw = Omit<DocRow, 'document_lines'> & { lines_count: number | string; total_count: number | string };

export const PAGE_SIZE = 100;

export async function fetchDocPage(supabase: SupabaseClient, q: DocQuery, offset: number, limit = PAGE_SIZE): Promise<{ rows: DocRow[]; total: number }> {
  const { data, error } = await supabase.rpc('documents_search', {
    p_type: q.type, p_kitchen: q.kitchenId, p_from: q.from, p_to: q.to, p_mode: q.mode ?? 'own', p_include_open: q.includeOpen ?? false,
    p_q: q.q?.trim() || null, p_status: q.status || null, p_limit: limit, p_offset: offset, p_reversals: q.reversals ?? false,
  });
  if (error) throw new Error(error.message);
  const raw = (data ?? []) as Raw[];
  return {
    rows: raw.map(({ lines_count, total_count: _t, ...d }) => ({ ...d, document_lines: [{ count: Number(lines_count) }] })),
    total: raw.length ? Number(raw[0].total_count) : 0,
  };
}

// كل المستندات المطابقة (لـ Export كامل مش بس اللي على الشاشة)
export async function fetchAllDocs(supabase: SupabaseClient, q: DocQuery): Promise<DocRow[]> {
  const out: DocRow[] = [];
  for (let off = 0; ; off += 1000) {
    const { rows, total } = await fetchDocPage(supabase, q, off, 1000);
    out.push(...rows);
    if (!rows.length || out.length >= total) break;
  }
  return out;
}

// Backup كامل (Admin): كل جداول البيانات كـ CSV جوه ملف ZIP واحد
import type { SupabaseClient } from '@supabase/supabase-js';
import { toCsv, ymd } from '@/lib/export';
import { makeZip } from '@/lib/zip';

export type BackupTable = { name: string; key: string[]; heavy?: boolean };
// key: عمود/أعمدة الترتيب. عمود واحد = keyset (سريع على الجداول الكبيرة)، أكتر من عمود = offset
export const BACKUP_TABLES: BackupTable[] = [
  { name: 'kitchens', key: ['id'] }, { name: 'products', key: ['id'] }, { name: 'reasons', key: ['id'] }, { name: 'periods', key: ['id'] },
  { name: 'profiles', key: ['user_id'] }, { name: 'user_kitchens', key: ['user_id', 'kitchen_id'] }, { name: 'user_pages', key: ['user_id', 'page_key'] },
  { name: 'access_invites', key: ['email'] },
  { name: 'documents', key: ['id'] }, { name: 'document_lines', key: ['id'] }, { name: 'transfer_lines', key: ['line_id'] },
  { name: 'stock_ledger', key: ['id'], heavy: true }, { name: 'stock_balances', key: ['kitchen_id', 'location', 'product_id'] },
  { name: 'stock_levels', key: ['id'] }, { name: 'document_line_edits', key: ['id'] },
  { name: 'audit_log', key: ['id'], heavy: true },
];

const cell = (v: unknown): string | number | boolean | null =>
  v === null || v === undefined ? null : typeof v === 'object' ? JSON.stringify(v) : (v as string | number | boolean);

export async function fetchTable(sb: SupabaseClient, t: BackupTable, onRows?: (n: number) => void): Promise<Record<string, unknown>[]> {
  const out: Record<string, unknown>[] = [];
  const single = t.key.length === 1 ? t.key[0] : null;
  let last: unknown = null;
  for (let off = 0; ; off += 1000) {
    let q = sb.from(t.name).select('*');
    for (const k of t.key) q = q.order(k, { ascending: true });
    q = single && last !== null ? q.gt(single, last as string | number) : q;
    q = single ? q.limit(1000) : q.range(off, off + 999);
    const { data, error } = await q;
    if (error) throw new Error(`${t.name}: ${error.message}`);
    const rows = (data ?? []) as Record<string, unknown>[];
    out.push(...rows); onRows?.(out.length);
    if (rows.length < 1000) break;
    if (single) last = rows[rows.length - 1][single];
  }
  return out;
}

export function tableCsv(rows: Record<string, unknown>[]): string {
  const headers = rows.length ? Object.keys(rows[0]) : [];
  return toCsv(headers, rows.map((r) => headers.map((h) => cell(r[h]))));
}

export async function runBackup(sb: SupabaseClient, tables: BackupTable[], onProgress: (t: string, n: number) => void): Promise<{ blob: Blob; name: string; counts: Record<string, number> }> {
  const enc = new TextEncoder();
  const files: { name: string; data: Uint8Array }[] = [];
  const counts: Record<string, number> = {};
  for (const t of tables) {
    const rows = await fetchTable(sb, t, (n) => onProgress(t.name, n));
    counts[t.name] = rows.length;
    files.push({ name: `${t.name}.csv`, data: enc.encode(tableCsv(rows)) });
  }
  files.push({ name: 'README.txt', data: enc.encode(`KMS backup ${new Date().toISOString()}\n${Object.entries(counts).map(([k, v]) => `${k}: ${v} rows`).join('\n')}\n`) });
  return { blob: makeZip(files), name: `kms-backup-${ymd(new Date())}.zip`, counts };
}

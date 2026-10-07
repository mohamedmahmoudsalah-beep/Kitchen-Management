export type Role = 'admin' | 'manager' | 'kitchen_user' | 'viewer';

export type Profile = {
  user_id: string;
  email: string;
  full_name: string | null;
  role: Role;
  is_active: boolean;
  is_root: boolean;
};

export type Kitchen = { id: string; code: string; name: string };
export type PageDef = { key: string; title: string; sort: number };

export type Product = {
  id: string;
  generic_code: string | null;
  syt_code: string;
  name: string;
  category: string | null;
  uom_name: string | null;
  uom_factor: number;       // Base Qty per Syt
  cost: number;             // تكلفة كود السيستم
  cost_per_uom: number;     // تكلفة الوحدة الأساسية
  cost_mismatch: boolean;
  is_active: boolean;
};

export type Reason = { id: string; name: string; direction: 'INCREASE' | 'DECREASE' | 'ANY'; is_active: boolean; is_system: boolean };

export type ImportErrorRow = {
  id: number;
  batch_id: string;
  module: string;
  kitchen_id: string | null;
  row_no: number;
  column_name: string | null;
  reason: string;
  raw: Record<string, unknown> | null;
  created_at: string;
};

export type AuditRow = {
  id: number;
  at: string;
  user_email: string | null;
  table_name: string;
  row_id: string | null;
  action: string;
  kitchen_id: string | null;
  old_data: Record<string, unknown> | null;
  new_data: Record<string, unknown> | null;
};

export type DocumentRow = {
  id: string;
  doc_no: string;
  doc_type: string;
  doc_date: string;
  status: string;
  note: string | null;
  override_reason: string | null;
  reverses_document_id: string | null;
  created_at: string;
  document_lines: { count: number }[];
};

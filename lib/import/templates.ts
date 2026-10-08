import type { SupabaseClient } from '@supabase/supabase-js';
import { MODULES, type ImportModule } from '@/lib/import/columns';
import { ymd } from '@/lib/export';

type Cell = string | number | null;

export type Sample = { syt_code: string; generic_code: string | null; name: string; category: string | null; uom_name: string | null; uom_factor: number; cost: number; cost_per_uom: number };

const FALLBACK: Sample[] = [
  { syt_code: '1001', generic_code: 'G-01', name: 'Flour 5kg bag', category: 'Dry goods', uom_name: 'Unit', uom_factor: 5, cost: 52.5, cost_per_uom: 10.5 },
  { syt_code: '1002', generic_code: 'G-02', name: 'Sugar 1kg', category: 'Dry goods', uom_name: 'Kg', uom_factor: 1, cost: 20, cost_per_uom: 20 },
  { syt_code: '1003', generic_code: 'G-03', name: 'Olive oil 2L', category: 'Oils', uom_name: 'Unit', uom_factor: 2, cost: 180, cost_per_uom: 90 },
];

export const NOTES: Record<ImportModule, string[]> = {
  products: [
    'Syt Code: كود السيستم — هو المفتاح (لازم يكون فريد). لو موجود بيتحدّث، لو مش موجود بيتضاف (حسب اختيارك: إضافة وتحديث / إضافة بس / تحديث بس).',
    'Generic Code: ممكن يتكرر على أكتر من منتج.',
    'Product Name: مطلوب للمنتج الجديد.',
    'UoM: وصف الوحدة زي ما هو في Odoo (للعرض بس).',
    'Product/Financial Category: التصنيف.',
    'Base Qty per Syt: كود السيستم الواحد = كام كيلو/وحدة أساسية (مثلًا 5). ده اللي بيحوّل بين القطعة والكيلو.',
    'Cost: تكلفة كود السيستم (القطعة/العبوة). Cost Pr UOM: تكلفة الكيلو/الوحدة الأساسية. لو كتبت واحد بس التاني بيتحسب.',
    'القيم الفاضية في ملف التحديث بتحافظ على القيمة الحالية.',
  ],
  opening: [
    'الرصيد الافتتاحي الأول للمطبخ المختار: تاريخ واحد، ومنتج مرة واحدة. بعد كده كل فترة بتبدأ من جرد الفترة اللي قبلها.',
    'Date: yyyy-mm-dd (أو dd/mm/yyyy). Code: Syt Code أو Generic Code.',
    'Qty: بالكيلو (الوحدة الأساسية) افتراضيًا. تقدر تستخدم عمود Qty Pieces (عدد أكواد السيستم) أو Qty Base بدل Qty.',
  ],
  purchases: [
    'Date: yyyy-mm-dd (أو dd/mm/yyyy). Code: Syt Code أو Generic Code.',
    'Qty: بالكيلو (الوحدة الأساسية) افتراضيًا. تقدر تستخدم Qty Pieces أو Qty Base بدل Qty.',
    'الصفوف بنفس التاريخ بتتجمّع في مستند واحد.',
  ],
  wh_txn: [
    'Warehouse Transactions: صرف من المخزن. Qty لازم تكون أقل من أو تساوي الرصيد المتاح.',
    'Qty: بالكيلو (الوحدة الأساسية) افتراضيًا، أو Qty Pieces / Qty Base.',
  ],
  waste: [
    'Waste: الكمية بتخصم من المخزون. Reason إجباري ولازم يكون من قايمة الأسباب (ممكن تضيف سبب من صفحة Waste).',
    'Qty: بالكيلو (الوحدة الأساسية) افتراضيًا، أو Qty Pieces / Qty Base.',
  ],
  adjustments: [
    'Qty بإشارة: موجب = زيادة، سالب = نقص. لازم تتوافق مع اتجاه السبب: Overage = زيادة بس، Missing/Damage/Expired = نقص بس، Count Correction/Merge = أي إشارة.',
    'Reason إجباري من قايمة الأسباب. السبب اللي اتجاهه زيادة أو نقص بس بيرفض الإشارة العكسية.',
  ],
  closing: [
    'الجرد الفعلي لتاريخ واحد. Qty = الكمية المجرودة (الصفر مسموح). المنتج مرة واحدة.',
    'بعد الحفظ الفروق عن رصيد الدفتر بتتسجل تلقائيًا كتسوية Count Correction، والجرد ده بيبقى Opening الفترة اللي بعده.',
    'المنتج اللي مش في الملف مش بيتعدل في المخزون، وبيتحسب Closing = 0 في تقرير الاستهلاك.',
  ],
  transfers: [
    'كل رفع بيتم من المطبخ المختار فوق (المرسل). To = اسم المطبخ المستلم (Plus Mall / Rehab / Maadi / NC7).',
    'التحويل بيتبعت وبيبقى In Transit، والمطبخ المستلم يأكد الكمية الفعلية من صفحته. الصفوف بنفس التاريخ والمستلم بتتجمّع في تحويل واحد.',
    'Qty: بالكيلو (الوحدة الأساسية) افتراضيًا، أو Qty Pieces / Qty Base.',
  ],
};

// صفوف المثال (بتتبني من منتجات حقيقية لو موجودة) — دالة صافية عشان تتختبر
export function buildTemplateRows(module: ImportModule, items: Sample[], today: string, otherKitchen: string): Cell[][] {
  const num = (v: unknown) => Number(v);
  return items.map((p, i) => {
    switch (module) {
      case 'products':
        return [p.syt_code, p.generic_code, p.name, p.uom_name, p.category, num(p.uom_factor), num(p.cost), num(p.cost_per_uom)];
      case 'adjustments':
        return [today, p.syt_code, i === 0 ? 10 : -[0, 5, 2][i], i === 0 ? 'Overage' : 'Missing', i === 0 ? 'مثال' : ''];
      case 'waste':
        return [today, p.syt_code, [3, 1.5, 2][i], i === 0 ? 'Damage' : 'Expired', ''];
      case 'transfers':
        return [today, otherKitchen, p.syt_code, [20, 10, 5][i], ''];
      default:
        return [today, p.syt_code, [100, 50, 25][i], ''];
    }
  });
}

export function sampleItems(data: Sample[] | null | undefined): Sample[] {
  return data && data.length ? data.slice(0, 3) : FALLBACK;
}

// بيحمّل ملف Excel مثال للـ Template (أعمدة + صفوف مثال من منتجاتك الفعلية + شيت ملاحظات)
export async function downloadTemplate(supabase: SupabaseClient, module: ImportModule, kitchenNames: string[] = [], currentKitchen = '') {
  const spec = MODULES[module];
  const { data } = await supabase.from('products')
    .select('syt_code,generic_code,name,category,uom_name,uom_factor,cost,cost_per_uom').eq('is_active', true).order('syt_code').limit(3);
  const other = kitchenNames.find((n) => n !== currentKitchen) ?? 'Maadi';
  const rows = buildTemplateRows(module, sampleItems(data as Sample[] | null), ymd(new Date()), other);

  const { default: writeExcelFile } = await import('write-excel-file/browser');
  const header = spec.template.map((h) => ({ value: h, fontWeight: 'bold' as const }));
  const notes = [[{ value: spec.label, fontWeight: 'bold' as const }], [''], ...NOTES[module].map((t) => [t])];
  const blob = await writeExcelFile([
    { data: [header, ...rows] as never, sheet: 'Template', columns: spec.template.map((h) => ({ width: Math.max(14, h.length + 4) })) },
    { data: notes as never, sheet: 'Notes', columns: [{ width: 120 }] },
  ] as never).toBlob();

  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url; a.download = `${module}-template.xlsx`; document.body.appendChild(a); a.click(); a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

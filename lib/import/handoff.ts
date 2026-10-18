// تسليم ملف من صفحة (مثلًا Purchases) لصفحة الـ Import من غير ما المستخدم يختاره تاني.
// الملف بيتحفظ في الذاكرة بس (مش في أي تخزين) وبيتاخد مرة واحدة.
let pending: File | null = null;
export const setPendingImportFile = (f: File | null) => { pending = f; };
export const takePendingImportFile = (): File | null => { const f = pending; pending = null; return f; };
export const isSheetFile = (f: File) => /\.(xlsx|csv|txt)$/i.test(f.name);

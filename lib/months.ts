// شهور كاملة: 'YYYY-MM' → أول وآخر يوم
export function monthRange(fromMonth: string, toMonth: string): { from: string; to: string } | null {
  if (!/^\d{4}-\d{2}$/.test(fromMonth) || !/^\d{4}-\d{2}$/.test(toMonth) || fromMonth > toMonth) return null;
  const [y, m] = toMonth.split('-').map(Number);
  const last = new Date(y, m, 0).getDate();
  return { from: `${fromMonth}-01`, to: `${toMonth}-${String(last).padStart(2, '0')}` };
}
export const prevMonth = (d = new Date()): string => {
  const x = new Date(d.getFullYear(), d.getMonth() - 1, 1);
  return `${x.getFullYear()}-${String(x.getMonth() + 1).padStart(2, '0')}`;
};
export const curMonth = (d = new Date()): string => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}`;

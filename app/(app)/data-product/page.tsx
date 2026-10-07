import ProductsView from '@/components/ProductsView';
import { requirePage } from '@/lib/auth';

export default async function DataProductPage() {
  const s = await requirePage('data_product');
  const role = s.profile.role;
  return <ProductsView canManage={role === 'admin' || role === 'manager'} isAdmin={role === 'admin'} />;
}

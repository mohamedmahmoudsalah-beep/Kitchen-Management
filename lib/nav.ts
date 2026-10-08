// href لكل صفحة + تجميعها في الـ Sidebar
export const PAGE_HREF: Record<string, string> = {
  dashboard: '/',
  opening_balance: '/opening-balance',
  purchases: '/purchases',
  kitchens_transfer: '/kitchens-transfer',
  warehouse_transactions: '/warehouse-transactions',
  waste: '/waste',
  closing_stock_count: '/closing-stock-count',
  consumption: '/consumption',
  warehouse_stock: '/warehouse-stock',
  stock_adjustments: '/stock-adjustments',
  data_product: '/data-product',
  import_export: '/import-export',
  import_errors: '/import-errors',
  access_control: '/access-control',
  audit_log: '/audit-log',
};

export const NAV_GROUPS: { title: string; keys: string[] }[] = [
  { title: 'Overview', keys: ['dashboard'] },
  { title: 'Operations', keys: ['opening_balance', 'purchases', 'kitchens_transfer', 'warehouse_transactions', 'waste', 'closing_stock_count', 'stock_adjustments'] },
  { title: 'Reports', keys: ['consumption', 'warehouse_stock'] },
  { title: 'Data', keys: ['data_product', 'import_export', 'import_errors'] },
  { title: 'Admin', keys: ['access_control', 'audit_log'] },
];

// صفحات مش مرتبطة بمطبخ/فترة
export const GLOBAL_PAGES = new Set(['data_product', 'access_control']);

// الصفحات اللي ليها Import من الملف + نوع المستند
export const IMPORT_MODULE_OF_PAGE: Record<string, string> = {
  opening_balance: 'opening',
  purchases: 'purchases',
  warehouse_transactions: 'wh_txn',
  waste: 'waste',
  stock_adjustments: 'adjustments',
  closing_stock_count: 'closing',
  kitchens_transfer: 'transfers',
};

export const DOC_TYPE_OF_PAGE: Record<string, string> = {
  opening_balance: 'OPENING',
  purchases: 'PURCHASE',
  warehouse_transactions: 'WH_TXN',
  waste: 'WASTE',
  stock_adjustments: 'ADJUSTMENT',
  closing_stock_count: 'CLOSING',
};

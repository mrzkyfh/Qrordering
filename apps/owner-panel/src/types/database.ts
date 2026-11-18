// ─── Enum Types ──────────────────────────────────────────────────────────────

export type UserRole = 'owner' | 'admin' | 'manajer' | 'kasir' | 'pelanggan'

/** Manajer tetap punya identitas role sendiri, tetapi batas aksesnya setara admin. */
export function normalizeUserRole(role: UserRole): UserRole {
  return role === 'manajer' ? 'admin' : role
}

export function userRoleHasAccess(role: UserRole, allowedRoles: UserRole[]): boolean {
  const normalizedRole = normalizeUserRole(role)
  return allowedRoles.some((allowedRole) => normalizeUserRole(allowedRole) === normalizedRole)
}
export type OrderStatus =
  | 'draft'
  | 'confirmed'
  | 'preparing'
  | 'ready'
  | 'served'
  | 'paid'
  | 'cancelled'
  | 'void'
export type PaymentMethod =
  | 'cash'
  | 'qris'
  | 'debit'
  | 'credit'
  | 'ewallet'
  | 'transfer'
export type TableStatus = 'available' | 'occupied' | 'reserved' | 'dirty'
export type StockTransactionType =
  | 'purchase'
  | 'usage'
  | 'adjustment'
  | 'waste'
  | 'return'
export type PromoType = 'percentage' | 'fixed' | 'bundling' | 'bogo'
export type ExpenseCategory =
  | 'bahan_baku'
  | 'operasional'
  | 'gaji'
  | 'peralatan'
  | 'marketing'
  | 'lain_lain'
export type OrderType = 'dine_in' | 'takeaway' | 'self_order'

// Kolom profil yang aman dibaca aplikasi web. Jangan gunakan `select('*')`:
// tabel profiles juga menyimpan hash PIN dan metadata percobaan PIN.
export const PROFILE_SELECT_COLUMNS =
  'id, outlet_id, role, full_name, login_email, phone, avatar_url, is_active, can_refund, last_login_at, device_last_seen_at, device_app_version, created_at, updated_at' as const

// ─── Table Types ──────────────────────────────────────────────────────────────

export interface TaxConfig {
  id: string
  name: string
  percent: number
  active: boolean
  inclusive: boolean
  calculation: 'before_discount' | 'after_discount'
  order_types: string[]
}

export interface OutletSettings {
  tax_percent: number
  service_charge_percent: number
  currency: string
  receipt_footer: string
  // Customer menu - hanya URL ini yang dipublikasikan ke projection anonim.
  customer_menu_cover_url?: string | null
  // Payment
  payment_methods?: string[]
  qris_image_url?: string | null
  qris_merchant_name?: string
  payment_timeout_minutes?: number
  kitchen_after_payment?: boolean
  allow_payment_proof?: boolean
  timezone?: string
  paper_size?: '58mm' | '80mm'
  auto_print_receipt?: boolean
  table_session_minutes?: number
  default_low_stock_threshold?: number
  auto_close_out_of_stock?: boolean
  // Tax (legacy single-tax fields — digunakan sebagai fallback)
  tax_name?: string
  tax_inclusive?: boolean
  tax_active?: boolean
  tax_calculation?: 'before_discount' | 'after_discount'
  tax_order_types?: string[]
  // Multiple taxes
  taxes?: TaxConfig[]
  // Charges
  rounding?: number
  // Receipt - Header values
  business_name?: string
  receipt_province?: string
  receipt_country?: string
  // Receipt - Header toggles
  receipt_show_logo?: boolean
  receipt_logo_style?: 'normal' | 'full'
  receipt_logo_url?: string | null
  receipt_show_business_name?: boolean
  receipt_show_outlet_name?: boolean
  receipt_show_address?: boolean
  receipt_show_phone?: boolean
  receipt_show_city?: boolean
  receipt_show_province?: boolean
  receipt_show_country?: boolean
  // Receipt - Custom fields
  receipt_custom_header_fields?: Array<{ id: string; label: string; value: string; visible: boolean }>
  receipt_custom_body_fields?: Array<{ id: string; label: string; value: string; visible: boolean }>
  // Receipt - Body
  receipt_limit_print?: boolean
  receipt_custom_header?: boolean
  receipt_custom_header_text?: string
  receipt_custom_header_align?: 'left' | 'center' | 'right'
  receipt_show_order_number?: boolean
  receipt_show_order_time?: boolean
  receipt_show_cashier?: boolean
  receipt_show_cashier_pay?: boolean
  receipt_show_customer?: boolean
  receipt_show_table?: boolean
  receipt_show_waiter?: boolean
  receipt_show_order_type?: boolean
  receipt_show_order_name?: boolean
  // Stasiun cetak (tiket dapur/bar)
  print_stations?: Array<{ id: string; name: string }>
  print_category_station?: Record<string, string>
  print_excluded_categories?: string[]
}

export interface MenuDepartment {
  id: string
  outlet_id: string
  name: string
  color: string | null
  sort_order: number
  is_active: boolean
}

export type ExtraType = 'optional' | 'required'
export type ExtraSelectionType = 'single' | 'multiple'

export interface MenuExtraOption {
  id: string
  extra_id: string
  name: string
  price: number
  sort_order: number
}

export interface MenuExtra {
  id: string
  outlet_id: string
  name: string
  type: ExtraType
  selection_type: ExtraSelectionType
  is_active: boolean
  sort_order: number
  created_at: string
  menu_extra_options?: MenuExtraOption[]
}

export interface LoyaltySettings {
  points_per_rupiah: number
  redeem_rate: number
  tier_threshold: Record<string, number>
}

export interface Outlet {
  id: string
  name: string
  address: string | null
  phone: string | null
  city: string | null
  logo_url: string | null
  is_active: boolean
  settings: OutletSettings
  loyalty_settings: LoyaltySettings | null
  created_at: string
  updated_at: string
}

export interface Profile {
  id: string
  outlet_id: string | null
  role: UserRole
  full_name: string
  login_email: string | null
  phone: string | null
  avatar_url: string | null
  is_active: boolean
  can_refund: boolean
  last_login_at: string | null
  device_last_seen_at: string | null
  device_app_version: string | null
  created_at: string
  updated_at: string
}

export interface RestaurantTable {
  id: string
  outlet_id: string
  table_number: string
  area: string | null
  capacity: number
  status: TableStatus
  qr_token: string | null
  qr_code_url: string | null
  qr_generated_at: string | null
  is_active: boolean
}

export interface MenuCategory {
  id: string
  outlet_id: string
  name: string
  icon: string | null
  sort_order: number
  is_active: boolean
  department_id: string | null
  menu_departments?: MenuDepartment
}

export interface MenuItemExtra {
  menu_item_id: string
  extra_id: string
  menu_extras?: MenuExtra
}

export interface MenuItemVariant {
  name: string
  price_addition: number
}

export interface MenuItem {
  id: string
  outlet_id: string
  category_id: string | null
  name: string
  description: string | null
  price: number
  image_url: string | null
  is_available: boolean
  is_active: boolean
  is_featured: boolean
  allow_price_override: boolean
  show_in_qr_menu: boolean
  preparation_time: number | null
  tags: string[] | null
  variants: MenuItemVariant[] | null
  sort_order: number
  updated_at: string
  menu_categories?: MenuCategory
}

export interface OrderItem {
  id: string
  order_id: string
  menu_item_id: string
  quantity: number
  unit_price: number
  subtotal: number
  notes: string | null
  menu_items?: MenuItem
}

export interface Payment {
  id: string
  order_id: string
  outlet_id: string
  shift_id: string | null
  method: PaymentMethod
  amount: number
  reference_number: string | null
  paid_at: string
}

export interface Order {
  id: string
  outlet_id: string
  shift_id: string | null
  table_id: string | null
  order_number: string
  order_type: OrderType
  status: OrderStatus
  customer_name: string | null
  subtotal: number
  discount_amount: number
  /** Nilai potongan dari penukaran poin loyalty, terpisah dari promo/voucher. */
  loyalty_discount?: number
  tax_amount: number
  service_charge: number
  total_amount: number
  stock_deducted: boolean
  client_request_id?: string | null
  created_by: string | null
  created_at: string
  updated_at: string
  restaurant_tables?: RestaurantTable
  order_items?: OrderItem[]
  payments?: Payment[]
  /** Data transaksi sudah dipindahkan ke Storage privat. */
  archived?: boolean
  archive_path?: string | null
  archived_cashier_name?: string | null
  parent_order_id?: string | null
  payment_claims?: PaymentClaim[]
}

export type PaymentClaimStatus = 'PENDING' | 'WAITING_VERIFICATION' | 'PAID' | 'VERIFICATION_FAILED' | 'EXPIRED' | 'CANCELLED' | 'REFUNDED'
export interface PaymentClaim {
  id: string
  order_id: string
  outlet_id: string
  status: PaymentClaimStatus
  proof_url: string | null
  submitted_at: string | null
  expires_at: string
  reviewed_by: string | null
  reviewed_at: string | null
  rejection_reason: string | null
  created_at: string
  updated_at: string
}

export interface Ingredient {
  id: string
  outlet_id: string
  name: string
  unit: string
  cost_per_unit: number
  stock_qty: number
  min_stock_qty: number
  is_active: boolean
  created_at: string
  updated_at: string
}

export interface StockTransaction {
  id: string
  outlet_id: string
  ingredient_id: string
  order_id: string | null
  type: StockTransactionType
  qty_before: number
  qty: number
  qty_after: number
  cost_per_unit: number | null
  notes: string | null
  created_by: string | null
  created_at: string
  ingredients?: Ingredient
}

export interface MenuRecipe {
  id: string
  menu_item_id: string
  ingredient_id: string
  qty_per_portion: number
  created_at: string
  ingredients?: Pick<Ingredient, 'name' | 'unit'>
}

export interface Promo {
  id: string
  outlet_id: string
  name: string
  description: string | null
  type: PromoType
  value: number
  min_order: number
  max_discount: number | null
  start_date: string | null
  end_date: string | null
  usage_limit: number | null
  usage_count: number
  is_active: boolean
  created_at: string
  updated_at: string
}

export interface Voucher {
  id: string
  promo_id: string
  outlet_id: string
  code: string
  usage_limit: number | null
  usage_count: number
  is_active: boolean
  created_at: string
}

export interface Expense {
  id: string
  outlet_id: string
  category: ExpenseCategory
  amount: number
  description: string | null
  expense_date: string
  created_by: string | null
  cash_movement_id?: string | null
  created_at: string
}

export interface Shift {
  id: string
  outlet_id: string
  kasir_id: string
  start_time: string
  end_time: string | null
  opening_cash: number
  closing_cash: number | null
  expected_cash: number | null
  cash_difference: number | null
  notes: string | null
}

// ─── View Types ───────────────────────────────────────────────────────────────

export interface DailySales {
  outlet_id: string
  sale_date: string
  total_orders: number
  gross_revenue: number
  total_discount: number
  total_tax: number
  total_service_charge: number
  net_revenue: number
  total_refund: number
}

export interface TopMenuItem {
  outlet_id: string
  menu_item_id: string
  menu_item_name: string
  category_name: string | null
  qty_sold: number
  total_revenue: number
  sale_date: string
}

export interface PaymentSummary {
  outlet_id: string
  pay_date: string
  method: PaymentMethod
  total_transactions: number
  total_amount: number
}

export interface LowStockItem {
  ingredient_id: string
  outlet_id: string
  name: string
  unit: string
  stock_qty: number
  min_stock_qty: number
  cost_per_unit: number
  status: 'low' | 'critical' | 'out_of_stock'
}

export interface ProfitLoss {
  outlet_id: string
  month: string
  gross_revenue: number
  total_discount: number
  total_refund: number
  net_revenue: number
  cost_of_goods: number
  gross_profit: number
  total_expenses: number
  net_profit: number
}

export interface KasirPerformance {
  kasir_id: string
  kasir_name: string
  outlet_id: string
  total_orders: number
  total_revenue: number
}

export interface CategorySales {
  outlet_id: string
  category_id: string | null
  category_name: string | null
  sale_date: string
  qty_sold: number
  total_orders: number | null
  total_revenue: number
}

export interface DepartmentSales {
  outlet_id: string
  department_id: string | null
  department_name: string
  color: string | null
  sale_date: string
  total_orders: number
  qty_sold: number
  total_revenue: number
}

export interface DepartmentFinancialReconciliation {
  department_id: string | null
  department_name: string
  color: string | null
  total_orders: number
  qty_sold: number
  subtotal: number
  discount_amount: number
  tax_inclusive: number
  tax_exclusive: number
  service_charge: number
  rounding_amount: number
  refund_amount: number
  unallocated_adjustment: number
  net_receipts: number
}

export interface MenuSales {
  outlet_id: string
  menu_item_id: string
  menu_name: string
  price: number
  category_name: string | null
  department_name: string | null
  sale_date: string
  qty_sold: number
  total_revenue: number
  order_count: number
}

export interface TaxReport {
  outlet_id: string
  sale_date: string
  total_orders: number
  gross_revenue: number
  total_discount: number
  total_tax: number
  total_service_charge: number
  net_revenue: number
}

export interface ExtraOptionSales {
  outlet_id: string | null
  extra_id: string
  extra_name: string
  option_id: string
  option_name: string
  option_price: number
  sale_date: string | null
  qty_selected: number
  qty_refunded?: number
  gross_revenue?: number
  refund_amount?: number
  total_revenue: number
}

export interface PeakHours {
  outlet_id: string
  sale_date: string
  hour_of_day: number
  total_orders: number
  total_revenue: number
}

export interface StockDaily {
  outlet_id: string
  ingredient_id: string
  ingredient_name: string
  unit: string
  min_stock_qty: number
  txn_date: string
  total_in: number
  total_out: number
  net_change: number
}

export interface OrderAuditLog {
  id: string
  order_id: string
  outlet_id: string
  actor_id: string | null
  actor_name: string | null
  action: string
  old_value: Record<string, unknown> | null
  new_value: Record<string, unknown> | null
  notes: string | null
  created_at: string
}

export type LoyaltyTier = 'bronze' | 'silver' | 'gold' | 'platinum'
export type LoyaltyTransactionType = 'earn' | 'redeem' | 'adjustment' | 'expire'

export interface LoyaltyMember {
  id: string
  outlet_id: string
  phone: string
  name: string
  points: number
  tier: LoyaltyTier
  is_active: boolean
  created_at: string
  updated_at: string
}

export interface LoyaltyTransaction {
  id: string
  member_id: string
  outlet_id: string
  order_id: string | null
  type: LoyaltyTransactionType
  points: number
  description: string | null
  created_at: string
}

export interface LoyaltySummary {
  outlet_id: string
  tier: LoyaltyTier
  member_count: number
  total_points_outstanding: number
  active_members: number
}

// ─── Supabase Database Helper Type ────────────────────────────────────────────

export type Database = {
  public: {
    Tables: {
      outlets: {
        Row: Outlet
        Insert: Omit<Outlet, 'id' | 'created_at' | 'updated_at'>
        Update: Partial<Omit<Outlet, 'id' | 'created_at' | 'updated_at'>>
      }
      profiles: {
        Row: Profile
        Insert: Omit<Profile, 'created_at' | 'updated_at'>
        Update: Partial<Omit<Profile, 'id' | 'created_at' | 'updated_at'>>
      }
      restaurant_tables: {
        Row: RestaurantTable
        Insert: Omit<RestaurantTable, 'id'>
        Update: Partial<Omit<RestaurantTable, 'id'>>
      }
      menu_categories: {
        Row: MenuCategory
        Insert: Omit<MenuCategory, 'id'>
        Update: Partial<Omit<MenuCategory, 'id'>>
      }
      menu_items: {
        Row: MenuItem
        Insert: Omit<MenuItem, 'id'>
        Update: Partial<Omit<MenuItem, 'id'>>
      }
      orders: {
        Row: Order
        Insert: Omit<Order, 'id' | 'created_at' | 'updated_at'>
        Update: Partial<Omit<Order, 'id' | 'created_at' | 'updated_at'>>
      }
      order_items: {
        Row: OrderItem
        Insert: Omit<OrderItem, 'id'>
        Update: Partial<Omit<OrderItem, 'id'>>
      }
      ingredients: {
        Row: Ingredient
        Insert: Omit<Ingredient, 'id' | 'created_at' | 'updated_at'>
        Update: Partial<Omit<Ingredient, 'id' | 'created_at' | 'updated_at'>>
      }
      stock_transactions: {
        Row: StockTransaction
        Insert: Omit<StockTransaction, 'id' | 'created_at'>
        Update: Partial<Omit<StockTransaction, 'id' | 'created_at'>>
      }
      promos: {
        Row: Promo
        Insert: Omit<Promo, 'id' | 'usage_count' | 'created_at' | 'updated_at'>
        Update: Partial<Omit<Promo, 'id' | 'created_at' | 'updated_at'>>
      }
      vouchers: {
        Row: Voucher
        Insert: Omit<Voucher, 'id' | 'usage_count' | 'created_at'>
        Update: Partial<Omit<Voucher, 'id' | 'created_at'>>
      }
      expenses: {
        Row: Expense
        Insert: Omit<Expense, 'id' | 'created_at'>
        Update: Partial<Omit<Expense, 'id' | 'created_at'>>
      }
    }
    Views: {
      v_daily_sales: { Row: DailySales }
      v_top_menu_items: { Row: TopMenuItem }
      v_payment_summary: { Row: PaymentSummary }
      v_low_stock: { Row: LowStockItem }
      v_profit_loss: { Row: ProfitLoss }
      v_kasir_performance: { Row: KasirPerformance }
    }
    Functions: Record<string, never>
    Enums: {
      user_role: UserRole
      order_status: OrderStatus
      payment_method: PaymentMethod
      table_status: TableStatus
      stock_transaction_type: StockTransactionType
      promo_type: PromoType
      expense_category: ExpenseCategory
    }
  }
}

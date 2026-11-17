export interface ShiftCloseReportPayment {
  method: string
  amount: number
}

export interface ShiftCloseReportProduct {
  name: string
  quantity: number
  amount: number
}

export interface ShiftCloseReportExpense {
  id: string
  category: string
  description: string
  amount: number
  created_at: string
}

export interface ShiftCloseReport {
  shift_id: string
  outlet_id: string
  outlet: {
    name: string
    address: string
    phone: string
    city: string
  }
  cashier_id: string
  cashier_name: string
  opened_at: string
  closed_at: string
  opening_cash: number
  closing_cash: number
  expected_cash: number
  cash_difference: number
  cash_received: number
  non_cash_received: number
  total_receipts: number
  tax_total: number
  service_charge_total: number
  discount_total: number
  refund_total: number
  cash_in: number
  cash_out: number
  completed_transactions: number
  unpaid_transactions: number
  void_item_quantity: number
  void_item_amount: number
  product_quantity: number
  payment_methods: ShiftCloseReportPayment[]
  products: ShiftCloseReportProduct[]
  expenses: ShiftCloseReportExpense[]
  notes: string | null
}

type JsonRecord = Record<string, unknown>

function record(value: unknown): JsonRecord {
  return value && typeof value === 'object' && !Array.isArray(value)
    ? value as JsonRecord
    : {}
}

function number(value: unknown) {
  const parsed = Number(value ?? 0)
  return Number.isFinite(parsed) ? parsed : 0
}

function string(value: unknown, fallback = '') {
  return typeof value === 'string' ? value : fallback
}

function records(value: unknown) {
  return Array.isArray(value) ? value.map(record) : []
}

/** Normalisasi JSONB Postgres; NUMERIC kadang diterima sebagai string. */
export function normalizeShiftCloseReport(value: unknown): ShiftCloseReport {
  const data = record(value)
  const outlet = record(data.outlet)
  return {
    shift_id: string(data.shift_id),
    outlet_id: string(data.outlet_id),
    outlet: {
      name: string(outlet.name),
      address: string(outlet.address),
      phone: string(outlet.phone),
      city: string(outlet.city),
    },
    cashier_id: string(data.cashier_id),
    cashier_name: string(data.cashier_name, 'Kasir'),
    opened_at: string(data.opened_at),
    closed_at: string(data.closed_at),
    opening_cash: number(data.opening_cash),
    closing_cash: number(data.closing_cash),
    expected_cash: number(data.expected_cash),
    cash_difference: number(data.cash_difference),
    cash_received: number(data.cash_received),
    non_cash_received: number(data.non_cash_received),
    total_receipts: number(data.total_receipts),
    tax_total: number(data.tax_total),
    service_charge_total: number(data.service_charge_total),
    discount_total: number(data.discount_total),
    refund_total: number(data.refund_total),
    cash_in: number(data.cash_in),
    cash_out: number(data.cash_out),
    completed_transactions: number(data.completed_transactions),
    unpaid_transactions: number(data.unpaid_transactions),
    void_item_quantity: number(data.void_item_quantity),
    void_item_amount: number(data.void_item_amount),
    product_quantity: number(data.product_quantity),
    payment_methods: records(data.payment_methods).map((item) => ({
      method: string(item.method),
      amount: number(item.amount),
    })),
    products: records(data.products).map((item) => ({
      name: string(item.name, 'Menu'),
      quantity: number(item.quantity),
      amount: number(item.amount),
    })),
    expenses: records(data.expenses).map((item) => ({
      id: string(item.id),
      category: string(item.category, 'lain_lain'),
      description: string(item.description, 'Pengeluaran kasir'),
      amount: number(item.amount),
      created_at: string(item.created_at),
    })),
    notes: typeof data.notes === 'string' && data.notes.trim()
      ? data.notes
      : null,
  }
}

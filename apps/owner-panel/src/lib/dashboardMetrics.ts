export interface DailySalesMetricRow {
  gross_revenue: number | string | null
  total_orders: number | string | null
  total_discount: number | string | null
  total_tax?: number | string | null
  total_service_charge?: number | string | null
  net_revenue: number | string | null
}

export interface DailySalesMetrics {
  grossRevenue: number
  totalOrders: number
  totalDiscount: number
  totalTax: number
  totalServiceCharge: number
  totalReceipts: number
}

function finiteNumber(value: number | string | null | undefined): number {
  const parsed = Number(value ?? 0)
  return Number.isFinite(parsed) ? parsed : 0
}

// PostgREST dapat mengembalikan NUMERIC sebagai string. Seluruh dashboard wajib
// menormalisasikannya sebelum penjumlahan agar tidak terjadi concatenation.
export function summarizeDailySales(rows: DailySalesMetricRow[]): DailySalesMetrics {
  return rows.reduce<DailySalesMetrics>((total, row) => ({
    grossRevenue: total.grossRevenue + finiteNumber(row.gross_revenue),
    totalOrders: total.totalOrders + finiteNumber(row.total_orders),
    totalDiscount: total.totalDiscount + finiteNumber(row.total_discount),
    totalTax: total.totalTax + finiteNumber(row.total_tax),
    totalServiceCharge: total.totalServiceCharge + finiteNumber(row.total_service_charge),
    // Nama kolom lama di v_daily_sales adalah net_revenue, tetapi nilainya
    // merupakan total yang dibayar pelanggan termasuk pajak/service.
    totalReceipts: total.totalReceipts + finiteNumber(row.net_revenue),
  }), {
    grossRevenue: 0,
    totalOrders: 0,
    totalDiscount: 0,
    totalTax: 0,
    totalServiceCharge: 0,
    totalReceipts: 0,
  })
}

export function calculateNetProfit(
  netRevenue: number | string,
  costOfGoods: number | string,
  operatingExpenses: number | string,
): number {
  return finiteNumber(netRevenue) - finiteNumber(costOfGoods) - finiteNumber(operatingExpenses)
}

export function calculateNetRevenue(
  totalReceipts: number | string,
  totalTax: number | string,
  totalServiceCharge: number | string,
): number {
  return finiteNumber(totalReceipts) - finiteNumber(totalTax) - finiteNumber(totalServiceCharge)
}

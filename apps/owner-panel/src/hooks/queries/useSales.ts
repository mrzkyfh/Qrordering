import { useQuery } from '@tanstack/react-query'
import { format, endOfMonth } from 'date-fns'
import { supabase } from '@/lib/supabase'
import { useAuth } from '@/hooks/useAuth'
import type {
  DailySales, TopMenuItem, PaymentSummary, ProfitLoss,
  CategorySales, KasirPerformance, PeakHours,
  DepartmentSales, DepartmentFinancialReconciliation, MenuSales, TaxReport, ExtraOptionSales,
} from '@/types/database'
import type { DateRange } from '@/components/ui/DateRangePicker'

export function useDailySales(outletId: string | null, range: DateRange) {
  const { isOwner } = useAuth()
  return useQuery({
    queryKey: ['daily-sales', outletId, range.from, range.to],
    queryFn: async () => {
      let query = supabase
        .from('v_daily_sales')
        .select('outlet_id, sale_date, total_orders, gross_revenue, total_discount, total_tax, total_service_charge, net_revenue, total_refund')
        .gte('sale_date', format(range.from, 'yyyy-MM-dd'))
        .lte('sale_date', format(range.to, 'yyyy-MM-dd'))
        .order('sale_date')

      if (outletId) query = query.eq('outlet_id', outletId)

      const { data, error } = await query
      if (error) throw error
      return data as DailySales[]
    },
    enabled: !!outletId || isOwner(),
    refetchOnWindowFocus: true,
  })
}

export function useTopMenuItems(outletId: string | null, month: string) {
  const { isOwner } = useAuth()
  return useQuery({
    queryKey: ['top-menu', outletId, month],
    queryFn: async () => {
      const monthStart = `${month}-01`
      const monthEnd = format(endOfMonth(new Date(monthStart)), 'yyyy-MM-dd')
      const { data, error } = await supabase.rpc('report_top_menu_items', {
        p_outlet_id: outletId,
        p_date_from: monthStart,
        p_date_to: monthEnd,
        p_limit: 8,
      })
      if (error) throw error
      return (data ?? []) as TopMenuItem[]
    },
    enabled: !!outletId || isOwner(),
  })
}

export function useTopMenuItemsRange(outletId: string | null, dateFrom: string, dateTo: string) {
  const { isOwner } = useAuth()
  return useQuery({
    queryKey: ['top-menu-range', outletId, dateFrom, dateTo],
    queryFn: async () => {
      const { data, error } = await supabase.rpc('report_top_menu_items', {
        p_outlet_id: outletId,
        p_date_from: dateFrom,
        p_date_to: dateTo,
        p_limit: 8,
      })
      if (error) throw error
      return (data ?? []) as TopMenuItem[]
    },
    enabled: (!!outletId || isOwner()) && !!dateFrom && !!dateTo,
    refetchOnWindowFocus: true,
  })
}

export function usePaymentSummary(outletId: string | null, month: string) {
  const { isOwner } = useAuth()
  return useQuery({
    queryKey: ['payment-summary', outletId, month],
    queryFn: async () => {
      // pay_date is type DATE — cannot use LIKE. Use gte/lte with month boundary.
      const monthStart = `${month}-01`
      const monthEnd   = format(endOfMonth(new Date(monthStart)), 'yyyy-MM-dd')
      let query = supabase
        .from('v_payment_summary')
        .select('outlet_id, pay_date, method, total_transactions, total_amount')
        .gte('pay_date', monthStart)
        .lte('pay_date', monthEnd)

      if (outletId) query = query.eq('outlet_id', outletId)

      const { data, error } = await query
      if (error) throw error
      return data as PaymentSummary[]
    },
    enabled: !!outletId || isOwner(),
  })
}

export function usePaymentSummaryRange(outletId: string | null, dateFrom: string, dateTo: string) {
  const { isOwner } = useAuth()
  return useQuery({
    queryKey: ['payment-summary-range', outletId, dateFrom, dateTo],
    queryFn: async () => {
      let query = supabase
        .from('v_payment_summary')
        .select('outlet_id, pay_date, method, total_transactions, total_amount')
        .gte('pay_date', dateFrom)
        .lte('pay_date', dateTo)

      if (outletId) query = query.eq('outlet_id', outletId)

      const { data, error } = await query
      if (error) throw error
      return data as PaymentSummary[]
    },
    enabled: !!outletId || isOwner(),
    refetchOnWindowFocus: true,
  })
}

export function useProfitLoss(outletId: string | null, month: string) {
  const { isOwner } = useAuth()
  return useQuery({
    queryKey: ['profit-loss', outletId, month],
    queryFn: async () => {
      let query = supabase
        .from('v_profit_loss')
        .select('outlet_id, month, gross_revenue, total_discount, total_refund, net_revenue, cost_of_goods, gross_profit, total_expenses, net_profit')
        .eq('month', month)

      if (outletId) query = query.eq('outlet_id', outletId)

      const { data, error } = await query
      if (error) throw error
      return data as ProfitLoss[]
    },
    enabled: !!outletId || isOwner(),
  })
}

export interface ProfitLossRange {
  gross_revenue: number
  total_discount: number
  total_refund: number
  net_revenue: number
  cost_of_goods: number
  gross_profit: number
  total_expenses: number
  net_profit: number
}

const EMPTY_PROFIT_LOSS_RANGE: ProfitLossRange = {
  gross_revenue: 0,
  total_discount: 0,
  total_refund: 0,
  net_revenue: 0,
  cost_of_goods: 0,
  gross_profit: 0,
  total_expenses: 0,
  net_profit: 0,
}

export function useProfitLossRange(outletId: string | null, dateFrom: string, dateTo: string) {
  const { isOwner } = useAuth()
  return useQuery({
    queryKey: ['profit-loss-range', outletId, dateFrom, dateTo],
    queryFn: async () => {
      // RPC baru belum masuk ke generated Database type sampai type generation
      // berikutnya, jadi cast dibatasi hanya pada pemanggilan ini.
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const { data, error } = await (supabase as any).rpc('report_profit_loss_range', {
        p_outlet_id: outletId,
        p_date_from: dateFrom,
        p_date_to: dateTo,
      })
      if (error) throw error
      const row = data?.[0]
      if (!row) return EMPTY_PROFIT_LOSS_RANGE
      return {
        gross_revenue: Number(row.gross_revenue ?? 0),
        total_discount: Number(row.total_discount ?? 0),
        total_refund: Number(row.total_refund ?? 0),
        net_revenue: Number(row.net_revenue ?? 0),
        cost_of_goods: Number(row.cost_of_goods ?? 0),
        gross_profit: Number(row.gross_profit ?? 0),
        total_expenses: Number(row.total_expenses ?? 0),
        net_profit: Number(row.net_profit ?? 0),
      } satisfies ProfitLossRange
    },
    enabled: (!!outletId || isOwner()) && !!dateFrom && !!dateTo,
    refetchOnWindowFocus: true,
  })
}

export function useCategorySales(outletId: string | null, month: string) {
  const { isOwner } = useAuth()
  return useQuery({
    queryKey: ['category-sales', outletId, month],
    queryFn: async () => {
      const monthStart = `${month}-01`
      const monthEnd = format(endOfMonth(new Date(monthStart)), 'yyyy-MM-dd')
      const { data, error } = await supabase.rpc('report_category_sales', {
        p_outlet_id: outletId,
        p_date_from: monthStart,
        p_date_to: monthEnd,
      })
      if (error) throw error
      return data as CategorySales[]
    },
    enabled: !!outletId || isOwner(),
  })
}

export function useCategorySalesRange(outletId: string | null, dateFrom: string, dateTo: string) {
  const { isOwner } = useAuth()
  return useQuery({
    queryKey: ['category-sales-range', outletId, dateFrom, dateTo],
    queryFn: async () => {
      const { data, error } = await supabase.rpc('report_category_sales', {
        p_outlet_id: outletId,
        p_date_from: dateFrom,
        p_date_to: dateTo,
      })
      if (error) throw error
      return data as CategorySales[]
    },
    enabled: !!outletId || isOwner(),
    refetchOnWindowFocus: true,
  })
}

export function useKasirPerformance(outletId: string | null, month: string) {
  const { isOwner } = useAuth()
  return useQuery({
    queryKey: ['kasir-performance', outletId, month],
    queryFn: async () => {
      // v_kasir_performance punya kolom work_date (per hari) sejak migrasi 095.
      // Tanpa filter ini kartu "Kasir Terbaik" menampilkan data SEPANJANG MASA,
      // bukan bulan yang dipilih.
      const monthStart = `${month}-01`
      const monthEnd = format(endOfMonth(new Date(monthStart)), 'yyyy-MM-dd')
      let query = supabase
        .from('v_kasir_performance')
        .select('outlet_id, kasir_id, kasir_name, work_date, total_orders, total_revenue, avg_order_value, total_discount_given')
        .gte('work_date', monthStart)
        .lte('work_date', monthEnd)

      if (outletId) query = query.eq('outlet_id', outletId)

      const { data, error } = await query
      if (error) throw error
      return data as KasirPerformance[]
    },
    enabled: !!outletId || isOwner(),
  })
}

// v_kasir_performance punya kolom work_date (per hari) — bisa difilter rentang.
export function useKasirPerformanceRange(outletId: string | null, dateFrom: string, dateTo: string) {
  const { isOwner } = useAuth()
  return useQuery({
    queryKey: ['kasir-performance-range', outletId, dateFrom, dateTo],
    queryFn: async () => {
      let query = supabase
        .from('v_kasir_performance')
        .select('outlet_id, kasir_id, kasir_name, work_date, total_orders, total_revenue, avg_order_value, total_discount_given')
        .gte('work_date', dateFrom)
        .lte('work_date', dateTo)

      if (outletId) query = query.eq('outlet_id', outletId)

      const { data, error } = await query
      if (error) throw error
      return data as (KasirPerformance & { work_date: string })[]
    },
    enabled: !!outletId || isOwner(),
    refetchOnWindowFocus: true,
  })
}

export function useDepartmentSales(outletId: string | null, dateFrom: string, dateTo: string) {
  const { isOwner } = useAuth()
  return useQuery({
    queryKey: ['department-sales', outletId, dateFrom, dateTo],
    queryFn: async () => {
      const { data, error } = await supabase.rpc('report_department_sales', {
        p_outlet_id: outletId,
        p_date_from: dateFrom,
        p_date_to: dateTo,
      })
      if (error) throw error
      return data as DepartmentSales[]
    },
    enabled: !!outletId || isOwner(),
  })
}

export function useDepartmentFinancialReconciliation(
  outletId: string | null,
  dateFrom: string,
  dateTo: string,
) {
  const { isOwner } = useAuth()
  return useQuery({
    queryKey: ['department-financial-reconciliation', outletId, dateFrom, dateTo],
    queryFn: async () => {
      // RPC baru belum tersedia pada generated Database type sampai type generation berikutnya.
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const { data, error } = await (supabase as any).rpc(
        'report_department_financial_reconciliation',
        { p_outlet_id: outletId, p_date_from: dateFrom, p_date_to: dateTo },
      )
      if (error) throw error
      return ((data ?? []) as Record<string, unknown>[]).map((row) => ({
        department_id: row.department_id == null ? null : String(row.department_id),
        department_name: String(row.department_name ?? 'Tanpa Departemen'),
        color: row.color == null ? null : String(row.color),
        total_orders: Number(row.total_orders ?? 0),
        qty_sold: Number(row.qty_sold ?? 0),
        subtotal: Number(row.subtotal ?? 0),
        discount_amount: Number(row.discount_amount ?? 0),
        tax_inclusive: Number(row.tax_inclusive ?? 0),
        tax_exclusive: Number(row.tax_exclusive ?? 0),
        service_charge: Number(row.service_charge ?? 0),
        rounding_amount: Number(row.rounding_amount ?? 0),
        refund_amount: Number(row.refund_amount ?? 0),
        unallocated_adjustment: Number(row.unallocated_adjustment ?? 0),
        net_receipts: Number(row.net_receipts ?? 0),
      } satisfies DepartmentFinancialReconciliation))
    },
    enabled: (!!outletId || isOwner()) && !!dateFrom && !!dateTo,
    refetchOnWindowFocus: true,
  })
}

export function useMenuSales(outletId: string | null, dateFrom: string, dateTo: string) {
  const { isOwner } = useAuth()
  return useQuery({
    queryKey: ['menu-sales', outletId, dateFrom, dateTo],
    queryFn: async () => {
      const { data, error } = await supabase.rpc('report_menu_sales', {
        p_outlet_id: outletId,
        p_date_from: dateFrom,
        p_date_to: dateTo,
      })
      if (error) throw error
      return data as MenuSales[]
    },
    enabled: !!outletId || isOwner(),
  })
}

export type TaxReportPeriod = 'hari' | 'bulan' | 'tahun'

export function useTaxReport(
  outletId: string | null,
  dateFrom: string,
  dateTo: string,
  period: TaxReportPeriod = 'hari',
) {
  const { isOwner } = useAuth()
  return useQuery({
    queryKey: ['tax-report', outletId, dateFrom, dateTo, period],
    queryFn: async () => {
      const { data, error } = await supabase.rpc('report_tax_sales', {
        p_outlet_id: outletId,
        p_date_from: dateFrom,
        p_date_to: dateTo,
        p_period: period,
      })
      if (error) throw error
      return data as TaxReport[]
    },
    enabled: !!outletId || isOwner(),
  })
}

export function useExtraOptionSales(outletId: string | null, dateFrom: string, dateTo: string) {
  const { isOwner } = useAuth()
  type ExtraSalesResult = Pick<ExtraOptionSales,
    'option_id' | 'qty_selected' | 'qty_refunded' | 'gross_revenue' | 'refund_amount' | 'total_revenue'
  >
  return useQuery({
    queryKey: ['extra-option-sales', outletId, dateFrom, dateTo],
    queryFn: async () => {
      if (!outletId) return [] as ExtraSalesResult[]
      const params = {
        p_outlet_id: outletId,
        p_date_from: dateFrom,
        p_date_to: dateTo,
      }
      const detailed = await supabase.rpc('report_extra_option_sales_v2', params)
      if (!detailed.error) return detailed.data as ExtraSalesResult[]
      if (detailed.error.code !== 'PGRST202') throw detailed.error

      // Kompatibilitas selama migration v2 belum diterapkan di server.
      const fallback = await supabase.rpc('report_extra_option_sales', params)
      if (fallback.error) throw fallback.error
      return fallback.data as ExtraSalesResult[]
    },
    enabled: !!outletId || isOwner(),
  })
}

export function usePeakHours(outletId: string | null, dateFrom: string, dateTo: string) {
  const { isOwner } = useAuth()
  return useQuery({
    queryKey: ['peak-hours', outletId, dateFrom, dateTo],
    queryFn: async () => {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      let query = (supabase.from('v_peak_hours') as any)
        .select('outlet_id, sale_date, hour_of_day, total_orders, total_revenue')
        .gte('sale_date', dateFrom)
        .lte('sale_date', dateTo)

      if (outletId) query = query.eq('outlet_id', outletId)

      const { data, error } = await query
      if (error) throw error
      return data as PeakHours[]
    },
    enabled: !!outletId || isOwner(),
    refetchOnWindowFocus: true,
  })
}

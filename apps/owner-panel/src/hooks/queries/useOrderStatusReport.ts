import { useQuery } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'

export type OrderStatusReportType = 'void' | 'cancelled'

export interface OrderStatusReportRow {
  row_id: string
  order_id: string
  order_number: string
  status_at: string | null      // voided_at atau cancelled_at
  order_at: string              // created_at
  kasir_name: string | null
  otorisasi_name: string | null
  product_name: string | null
  quantity: number
  subtotal: number              // order_items.subtotal
  order_type: string            // 'dine_in' | 'takeaway' | 'self_order'
  table_number: string | null
  order_total: number           // orders.total_amount (untuk hitung Total Void unik per nota)
}

// Map slug → field timestamp di tabel orders (otorisasi sudah lewat join)
const TS_FIELD = { void: 'voided_at', cancelled: 'cancelled_at' } as const

const ROW_SELECT = `
  id, order_number, order_type, status, total_amount, created_at,
  voided_at, cancelled_at,
  kasir:created_by(full_name),
  authorizer_void:voided_by(full_name),
  authorizer_cancel:cancelled_by(full_name),
  table:table_id(table_number),
  order_items(quantity, subtotal, menu_items(name))
`

export interface OrderStatusFilters {
  dateFrom: string
  dateTo: string
  orderType?: string   // 'all' | order_type
  search?: string      // cocokkan order_number
}

export interface OrderStatusPageParams extends OrderStatusFilters {
  page: number        // 1-based
  pageSize: number    // jumlah baris detail per halaman
}

export interface OrderStatusPage {
  rows: OrderStatusReportRow[]   // sudah di-flatten ke level item
  totalOrders: number            // jumlah nota (untuk Total Transaksi + paginasi)
  totalAmount: number            // sum order.total_amount seluruh hasil filter (Total Void/Refund)
  totalRows: number              // jumlah baris detail untuk paginasi
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function applyStatusFilters(query: any, type: OrderStatusReportType, f: OrderStatusFilters) {
  const tsField = TS_FIELD[type]
  let q = query
    .eq('status', type)
    .gte(tsField, f.dateFrom)
    .lte(tsField, f.dateTo)
  if (f.orderType && f.orderType !== 'all') q = q.eq('order_type', f.orderType)
  if (f.search && f.search.trim()) {
    const s = f.search.trim().replace(/[%,]/g, '')
    q = q.ilike('order_number', `%${s}%`)
  }
  return q
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function flattenOrders(data: any[], type: OrderStatusReportType): OrderStatusReportRow[] {
  const rows: OrderStatusReportRow[] = []
  for (const o of data) {
    const statusAt   = type === 'void' ? o.voided_at : o.cancelled_at
    const authorizer = type === 'void' ? o.authorizer_void : o.authorizer_cancel
    const items: { quantity: number; subtotal: number; menu_items: { name: string } | null }[] =
      o.order_items ?? []
    const base = {
      row_id: `order:${o.id}:empty`,
      order_id: o.id,
      order_number: o.order_number,
      status_at: statusAt,
      order_at: o.created_at,
      kasir_name: o.kasir?.full_name ?? null,
      otorisasi_name: authorizer?.full_name ?? o.kasir?.full_name ?? null,
      order_type: o.order_type,
      table_number: o.table?.table_number ?? null,
      order_total: Number(o.total_amount ?? 0),
    }
    if (items.length === 0) {
      rows.push({ ...base, product_name: null, quantity: 0, subtotal: 0 })
    } else {
      for (const [index, item] of items.entries()) {
        rows.push({
          ...base,
          row_id: `order:${o.id}:${index}`,
          product_name: item.menu_items?.name ?? null,
          quantity: Number(item.quantity ?? 0),
          subtotal: Number(item.subtotal ?? 0),
        })
      }
    }
  }
  return rows
}

export function useOrderStatusReportPaged(
  outletId: string | null,
  type: OrderStatusReportType,
  params: OrderStatusPageParams,
) {
  const tsField = TS_FIELD[type]
  return useQuery({
    queryKey: ['order-status-report-paged', outletId, type, params],
    enabled: !!outletId,
    queryFn: async (): Promise<OrderStatusPage> => {
      if (type === 'void') {
        const rpcParams = {
          p_outlet_id: outletId,
          p_date_from: params.dateFrom,
          p_date_to: params.dateTo,
          p_order_type: params.orderType && params.orderType !== 'all' ? params.orderType : null,
          p_search: params.search?.trim() || null,
        }
        const [{ data: summaryData, error: summaryErr }, { data: detailData, error: detailErr }] =
          await Promise.all([
            supabase.rpc('report_void_summary', rpcParams),
            supabase.rpc('report_void_details', {
              ...rpcParams,
              p_limit: params.pageSize,
              p_offset: (params.page - 1) * params.pageSize,
            }),
          ])
        if (summaryErr) throw summaryErr
        if (detailErr) throw detailErr
        const summary = (summaryData?.[0] ?? {}) as {
          total_orders?: number
          total_rows?: number
          total_amount?: number
        }
        return {
          rows: (detailData ?? []).map(mapVoidDetail),
          totalOrders: Number(summary.total_orders ?? 0),
          totalRows: Number(summary.total_rows ?? 0),
          totalAmount: Number(summary.total_amount ?? 0),
        }
      }
      // 1) Ringkasan dihitung di database. Sebelumnya seluruh total_amount
      //    dikirim ke browser lalu dijumlahkan dengan reduce().
      const { data: summaryData, error: summaryErr } = await supabase.rpc(
        'report_order_status_summary',
        {
          p_outlet_id: outletId,
          p_status: type,
          p_date_from: params.dateFrom,
          p_date_to: params.dateTo,
          p_order_type: params.orderType && params.orderType !== 'all' ? params.orderType : null,
          p_search: params.search?.trim() || null,
        },
      )
      if (summaryErr) throw summaryErr
      const summary = (summaryData?.[0] ?? {}) as { total_orders?: number; total_amount?: number }
      const totalOrders = Number(summary.total_orders ?? 0)
      const totalAmount = Number(summary.total_amount ?? 0)

      // 2) Halaman: ambil N order (level nota) via .range() lalu flatten ke item.
      //    Detail item hanya dikirim untuk halaman yang sedang dilihat.
      const pageBase = (supabase.from('orders') as any) // eslint-disable-line @typescript-eslint/no-explicit-any
        .select(ROW_SELECT)
        .eq('outlet_id', outletId)
      let pageQ = applyStatusFilters(pageBase, type, params).order(tsField, { ascending: false })
      const from = (params.page - 1) * params.pageSize
      pageQ = pageQ.range(from, from + params.pageSize - 1)
      const { data: pageData, error: pageErr } = await pageQ
      if (pageErr) throw pageErr

      return {
        rows: flattenOrders(pageData ?? [], type),
        totalOrders,
        totalRows: totalOrders,
        totalAmount,
      }
    },
  })
}

// Ambil SEMUA baris (flattened item) sesuai filter, untuk ekspor utuh.
export async function fetchAllOrderStatusRows(
  outletId: string,
  type: OrderStatusReportType,
  filters: OrderStatusFilters,
): Promise<OrderStatusReportRow[]> {
  if (type === 'void') {
    const BATCH = 500
    const all: OrderStatusReportRow[] = []
    for (let offset = 0; ; offset += BATCH) {
      const { data, error } = await supabase.rpc('report_void_details', {
        p_outlet_id: outletId,
        p_date_from: filters.dateFrom,
        p_date_to: filters.dateTo,
        p_order_type: filters.orderType && filters.orderType !== 'all' ? filters.orderType : null,
        p_search: filters.search?.trim() || null,
        p_limit: BATCH,
        p_offset: offset,
      })
      if (error) throw error
      const batch = data ?? []
      all.push(...batch.map(mapVoidDetail))
      if (batch.length < BATCH) break
    }
    return all
  }
  const tsField = TS_FIELD[type]
  const BATCH = 500   // per nota; tiap nota bisa banyak item
  const all: OrderStatusReportRow[] = []
  for (let offset = 0; ; offset += BATCH) {
    const base = (supabase.from('orders') as any) // eslint-disable-line @typescript-eslint/no-explicit-any
      .select(ROW_SELECT)
      .eq('outlet_id', outletId)
    const q = applyStatusFilters(base, type, filters)
      .order(tsField, { ascending: false })
      .range(offset, offset + BATCH - 1)
    const { data, error } = await q
    if (error) throw error
    const batch = data ?? []
    all.push(...flattenOrders(batch, type))
    if (batch.length < BATCH) break
  }
  return all
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function mapVoidDetail(r: any): OrderStatusReportRow {
  return {
    row_id: String(r.row_id),
    order_id: r.order_id,
    order_number: r.order_number,
    status_at: r.status_at,
    order_at: r.order_at,
    kasir_name: r.kasir_name ?? null,
    otorisasi_name: r.otorisasi_name ?? null,
    product_name: r.product_name ?? null,
    quantity: Number(r.quantity ?? 0),
    subtotal: Number(r.subtotal ?? 0),
    order_type: r.order_type,
    table_number: r.table_number ?? null,
    order_total: Number(r.order_total ?? 0),
  }
}

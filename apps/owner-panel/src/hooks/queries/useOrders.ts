import { useQuery } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import { sanitizeSearch } from '@/lib/search'
import type { Order, OrderStatus, OrderType } from '@/types/database'

interface OrderFilters {
  status?: OrderStatus | OrderStatus[]
  orderType?: OrderType
  dateFrom?: string
  dateTo?: string
  createdBy?: string
  limit?: number
}

export function useOrders(outletId: string, filters: OrderFilters = {}) {
  return useQuery({
    queryKey: ['orders', outletId, filters],
    queryFn: async () => {
      let query = supabase
        .from('orders')
        .select('id, outlet_id, shift_id, table_id, parent_order_id, order_number, order_type, status, customer_name, subtotal, discount_amount, tax_amount, service_charge, total_amount, stock_deducted, created_by, created_at, updated_at, restaurant_tables(table_number, area), order_items(id, order_id, menu_item_id, quantity, unit_price, subtotal, notes, menu_items(name)), payments(id, method, amount, paid_at), payment_claims(id, order_id, outlet_id, status, proof_url, submitted_at, expires_at, reviewed_by, reviewed_at, rejection_reason, created_at, updated_at)')
        .eq('outlet_id', outletId)
        .order('created_at', { ascending: false })

      if (filters.status) {
        if (Array.isArray(filters.status)) {
          query = query.in('status', filters.status)
        } else {
          query = query.eq('status', filters.status)
        }
      }
      if (filters.orderType) query = query.eq('order_type', filters.orderType)
      if (filters.dateFrom) query = query.gte('created_at', filters.dateFrom)
      if (filters.dateTo)   query = query.lte('created_at', filters.dateTo)
      if (filters.createdBy) query = query.eq('created_by', filters.createdBy)
      if (filters.limit)    query = query.limit(filters.limit)

      const { data, error } = await query
      if (error) throw error
      return data as unknown as Order[]
    },
    enabled: !!outletId,
    staleTime: 30_000,
    refetchOnWindowFocus: true,
  })
}

export function useActiveOrders(outletId: string) {
  return useOrders(outletId, {
    status: ['confirmed', 'preparing', 'ready'],
    limit: 50,
  })
}

export interface ActiveOrderSummary {
  totalOrders: number
  totalAmount: number
  byOrderType: Record<string, number>
}

export function useActiveOrderSummary(outletId: string) {
  return useQuery({
    queryKey: ['active-order-summary', outletId],
    enabled: !!outletId,
    staleTime: 30_000,
    queryFn: async (): Promise<ActiveOrderSummary> => {
      // RPC baru belum masuk ke generated Database type sampai type generation
      // berikutnya, jadi cast dibatasi hanya pada pemanggilan ini.
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const { data, error } = await (supabase as any).rpc('report_active_order_summary', {
        p_outlet_id: outletId,
      })
      if (error) throw error
      const row = data?.[0]
      return {
        totalOrders: Number(row?.total_orders ?? 0),
        totalAmount: Number(row?.total_amount ?? 0),
        byOrderType: {
          dine_in: Number(row?.dine_in_orders ?? 0),
          takeaway: Number(row?.takeaway_orders ?? 0),
          self_order: Number(row?.self_order_orders ?? 0),
        },
      }
    },
  })
}

// ── Paginated orders (server-side) ──────────────────────────────────────────
// RPC menyatukan order aktif dan indeks arsip privat. File arsip lengkap hanya
// dibuka ketika pengguna memilih Detail, jadi daftar tetap ringan.

export interface OrdersPageParams {
  dateFrom?: string
  dateTo?: string
  status?: OrderStatus | OrderStatus[]
  orderType?: OrderType
  search?: string
  createdBy?: string
  page: number       // 1-based
  pageSize: number
}

export interface OrdersPage {
  rows: Order[]
  totalCount: number
}

export function useOrdersPaged(outletId: string, params: OrdersPageParams) {
  return useQuery({
    queryKey: ['orders-paged', outletId, params],
    enabled: !!outletId,
    staleTime: 30_000,
    queryFn: async (): Promise<OrdersPage> => {
      const from = (params.page - 1) * params.pageSize
      // RPC hanya menerima satu status. Mengambil satu halaman tanpa filter lalu
      // memfilternya di klien membuat total dan pagination salah. Untuk filter
      // multi-status, ambil setiap status secara lengkap, gabungkan, baru page.
      if (Array.isArray(params.status)) {
        const rows = await fetchAllOrders(outletId, {
          dateFrom: params.dateFrom,
          dateTo: params.dateTo,
          status: params.status,
          orderType: params.orderType,
          search: params.search,
          createdBy: params.createdBy,
        })
        return {
          rows: rows.slice(from, from + params.pageSize),
          totalCount: rows.length,
        }
      }

      const singleStatus = params.status ?? null
      const safeSearch = params.search ? sanitizeSearch(params.search) : ''
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const { data, error } = await (supabase as any).rpc('list_orders_unified', {
        p_outlet_id: outletId,
        p_date_from: params.dateFrom ?? null,
        p_date_to: params.dateTo ?? null,
        p_status: singleStatus,
        p_order_type: params.orderType ?? null,
        p_created_by: params.createdBy ?? null,
        p_search: safeSearch || null,
        p_offset: from,
        p_limit: params.pageSize,
      })
      if (error) throw error
      const rows = (data?.rows ?? []) as Order[]
      return { rows, totalCount: Number(data?.total_count ?? 0) }
    },
  })
}

// Ambil SEMUA order sesuai filter (untuk ekspor laporan utuh), batch 1000 via range.
export async function fetchAllOrders(
  outletId: string,
  filters: {
    dateFrom?: string
    dateTo?: string
    status?: OrderStatus | OrderStatus[]
    orderType?: OrderType
    search?: string
    createdBy?: string
  },
): Promise<Order[]> {
  if (Array.isArray(filters.status)) {
    const results = await Promise.all(filters.status.map((status) =>
      fetchAllOrders(outletId, { ...filters, status }),
    ))
    const unique = new Map<string, Order>()
    results.flat().forEach((order) => unique.set(order.id, order))
    return [...unique.values()].sort((a, b) =>
      new Date(b.created_at).getTime() - new Date(a.created_at).getTime(),
    )
  }

  const BATCH = 1000
  const all: Order[] = []
  for (let offset = 0; ; offset += BATCH) {
    const safeSearch = filters.search ? sanitizeSearch(filters.search) : ''
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const { data, error } = await (supabase as any).rpc('list_orders_unified', {
      p_outlet_id: outletId,
      p_date_from: filters.dateFrom ?? null,
      p_date_to: filters.dateTo ?? null,
      p_status: filters.status ?? null,
      p_order_type: filters.orderType ?? null,
      p_created_by: filters.createdBy ?? null,
      p_search: safeSearch || null,
      p_offset: offset,
      p_limit: BATCH,
    })
    if (error) throw error
    const batch = (data?.rows ?? []) as Order[]
    all.push(...batch)
    if (batch.length < BATCH) break
  }
  return all
}

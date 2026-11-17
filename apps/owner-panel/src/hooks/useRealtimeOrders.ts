import { useEffect } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'

type DashboardTable =
  | 'orders'
  | 'payments'
  | 'refunds'
  | 'expenses'
  | 'restaurant_tables'

interface DashboardBroadcast {
  payload?: {
    table?: DashboardTable
  }
}

const reportQueryKeys = [
  'daily-sales',
  'payment-summary-range',
  'top-menu-range',
  'category-sales-range',
  'kasir-performance-range',
  'profit-loss-range',
] as const

export function useRealtimeOrders(outletId: string | null) {
  const queryClient = useQueryClient()

  useEffect(() => {
    if (!outletId) return

    let refreshTimer: ReturnType<typeof setTimeout> | undefined
    let subscribedOnce = false
    const pendingTables = new Set<DashboardTable>()

    const flushRefresh = () => {
      refreshTimer = undefined
      const tables = new Set(pendingTables)
      pendingTables.clear()
      const refreshAll = tables.size === 0

      if (refreshAll || tables.has('orders')) {
        void queryClient.invalidateQueries({ queryKey: ['orders', outletId] })
        void queryClient.invalidateQueries({ queryKey: ['orders-paged', outletId] })
        void queryClient.invalidateQueries({ queryKey: ['active-order-summary', outletId] })
        void queryClient.invalidateQueries({ queryKey: ['report-paid-orders-by-cashier', outletId] })
      }
      if (refreshAll || tables.has('payments') || tables.has('refunds')) {
        for (const key of reportQueryKeys) {
          void queryClient.invalidateQueries({ queryKey: [key, outletId] })
        }
      }
      if (tables.has('expenses')) {
        void queryClient.invalidateQueries({ queryKey: ['profit-loss-range', outletId] })
      }
      if (tables.has('restaurant_tables')) {
        void queryClient.invalidateQueries({ queryKey: ['tables', outletId] })
      }
    }

    const scheduleRefresh = (table?: DashboardTable) => {
      if (table) pendingTables.add(table)
      if (refreshTimer) clearTimeout(refreshTimer)
      // Order + payment + perubahan status biasanya terjadi berdekatan.
      // Gabungkan semuanya menjadi satu gelombang refetch.
      refreshTimer = setTimeout(flushRefresh, 600)
    }

    const channel = supabase
      .channel(`dashboard:${outletId}`, { config: { private: true } })
      .on('broadcast', { event: 'change' }, (message: DashboardBroadcast) => {
        scheduleRefresh(message.payload?.table)
      })
      .subscribe((status) => {
        if (status !== 'SUBSCRIBED') return
        // Sesudah reconnect, refresh sekali untuk menutup event yang mungkin
        // terlewat. Subscribe pertama tidak perlu karena query sedang dimuat.
        if (subscribedOnce) scheduleRefresh()
        subscribedOnce = true
      })

    return () => {
      if (refreshTimer) clearTimeout(refreshTimer)
      void supabase.removeChannel(channel)
    }
  }, [outletId, queryClient])
}

export function useRealtimeTables(outletId: string | null) {
  const queryClient = useQueryClient()

  useEffect(() => {
    if (!outletId) return

    let refreshTimer: ReturnType<typeof setTimeout> | undefined
    let subscribedOnce = false
    const refresh = () => {
      if (refreshTimer) clearTimeout(refreshTimer)
      refreshTimer = setTimeout(() => {
        void queryClient.invalidateQueries({ queryKey: ['tables', outletId] })
      }, 400)
    }

    const channel = supabase
      .channel(`dashboard:${outletId}`, { config: { private: true } })
      .on('broadcast', { event: 'change' }, (message: DashboardBroadcast) => {
        if (message.payload?.table === 'restaurant_tables') refresh()
      })
      .subscribe((status) => {
        if (status !== 'SUBSCRIBED') return
        if (subscribedOnce) refresh()
        subscribedOnce = true
      })

    return () => {
      if (refreshTimer) clearTimeout(refreshTimer)
      void supabase.removeChannel(channel)
    }
  }, [outletId, queryClient])
}

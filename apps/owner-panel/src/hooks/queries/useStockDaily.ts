import { useQuery } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import type { StockDaily } from '@/types/database'

export function useStockDaily(outletId: string | null, dateFrom: string, dateTo: string) {
  return useQuery({
    queryKey: ['stock-daily', outletId, dateFrom, dateTo],
    queryFn: async () => {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const { data, error } = await (supabase.from('v_stock_daily') as any)
        .select('*')
        .eq('outlet_id', outletId)
        .gte('txn_date', dateFrom)
        .lte('txn_date', dateTo)
        .order('ingredient_name')
      if (error) throw error
      return data as StockDaily[]
    },
    enabled: !!outletId,
  })
}

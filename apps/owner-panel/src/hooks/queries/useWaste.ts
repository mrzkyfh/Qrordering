import { useQuery } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'

export interface WasteRow {
  id: string
  outlet_id: string
  ingredient_id: string
  ingredient_name: string
  unit: string
  qty: number
  cost_per_unit: number | null
  loss_value: number
  reason: string | null
  notes: string | null
  created_by: string | null
  created_at: string
  waste_date: string
}

// dateFrom / dateTo = 'yyyy-MM-dd' (waste_date sudah zona Asia/Jakarta)
export function useWaste(outletId: string | null, dateFrom: string, dateTo: string) {
  return useQuery({
    queryKey: ['waste', outletId, dateFrom, dateTo],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('v_waste')
        .select('*')
        .eq('outlet_id', outletId!)
        .gte('waste_date', dateFrom)
        .lte('waste_date', dateTo)
        .order('created_at', { ascending: false })
      if (error) throw error
      return data as WasteRow[]
    },
    enabled: !!outletId,
  })
}

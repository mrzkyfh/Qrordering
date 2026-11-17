import { useQuery } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'

export interface CashMovement {
  id: string
  shift_id: string
  outlet_id: string
  type: 'in' | 'out'
  amount: number
  note: string | null
  created_at: string
}

/** Pergerakan kas (masuk/keluar) untuk satu shift, terbaru dulu. */
export function useCashMovements(shiftId: string | null) {
  return useQuery({
    queryKey: ['cash-movements', shiftId],
    queryFn: async () => {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const { data, error } = await (supabase.from('cash_movements') as any)
        .select('*')
        .eq('shift_id', shiftId)
        .order('created_at', { ascending: false })
      if (error) throw error
      return (data ?? []) as CashMovement[]
    },
    enabled: !!shiftId,
  })
}

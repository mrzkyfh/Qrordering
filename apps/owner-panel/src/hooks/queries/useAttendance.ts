import { useQuery } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'

export interface AttendanceRow {
  id: string
  outlet_id: string
  staff_id: string
  staff_name: string
  staff_role: string
  clock_in: string
  clock_out: string | null
  note: string | null
  hours: number
  work_date: string
}

// dateFrom / dateTo = 'yyyy-MM-dd' (work_date zona Asia/Jakarta)
export function useAttendance(outletId: string | null, dateFrom: string, dateTo: string) {
  return useQuery({
    queryKey: ['attendance', outletId, dateFrom, dateTo],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('v_attendance')
        .select('*')
        .eq('outlet_id', outletId!)
        .gte('work_date', dateFrom)
        .lte('work_date', dateTo)
        .order('clock_in', { ascending: false })
      if (error) throw error
      return data as AttendanceRow[]
    },
    enabled: !!outletId,
  })
}

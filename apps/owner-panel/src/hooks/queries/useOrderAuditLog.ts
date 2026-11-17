import { useQuery } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import type { OrderAuditLog } from '@/types/database'

export function useOrderAuditLog(orderId: string | null) {
  return useQuery({
    queryKey: ['order-audit-log', orderId],
    queryFn: async () => {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const { data, error } = await (supabase.from('order_audit_log') as any)
        .select('id, order_id, actor_name, action, notes, created_at')
        .eq('order_id', orderId)
        .order('created_at', { ascending: false })
      if (error) throw error
      return data as OrderAuditLog[]
    },
    enabled: !!orderId,
  })
}

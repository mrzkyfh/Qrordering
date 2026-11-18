import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import type { PaymentClaim, PaymentClaimStatus } from '@/types/database'

export interface PaymentClaimRow extends PaymentClaim {
  orders?: { order_number: string; total_amount: number; table_id: string | null } | null
  profiles?: { full_name: string } | null
}

export function usePaymentClaims(outletId: string, statuses?: PaymentClaimStatus[]) {
  return useQuery({
    queryKey: ['payment-claims', outletId, statuses],
    enabled: !!outletId,
    queryFn: async () => {
      let query = supabase.from('payment_claims')
        .select('*, orders(order_number,total_amount,table_id), profiles:reviewed_by(full_name)')
        .eq('outlet_id', outletId)
        .order('submitted_at', { ascending: false })
      if (statuses?.length) query = query.in('status', statuses)
      const { data, error } = await query
      if (error) throw error
      return data as unknown as PaymentClaimRow[]
    },
  })
}

export function useReviewPaymentClaim(outletId: string) {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: async ({ id, decision, reason }: { id: string; decision: 'PAID' | 'VERIFICATION_FAILED' | 'CANCELLED'; reason?: string }) => {
      // Generated types diperbarui setelah migrasi diterapkan.
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const { data, error } = await (supabase as any).rpc('review_qris_payment_claim', { p_claim_id: id, p_decision: decision, p_reason: reason ?? null })
      if (error) throw error
      return data as PaymentClaim
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['payment-claims', outletId] })
      queryClient.invalidateQueries({ queryKey: ['orders'] })
      queryClient.invalidateQueries({ queryKey: ['orders-paged'] })
      queryClient.invalidateQueries({ queryKey: ['active-order-summary', outletId] })
    },
  })
}

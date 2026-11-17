import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import type { Voucher } from '@/types/database'

export type VoucherWithPromo = Voucher & { promos: { name: string } | null }

export function useVouchers(outletId: string | null, promoId?: string) {
  return useQuery({
    queryKey: ['vouchers', outletId, promoId ?? 'all'],
    queryFn: async () => {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      let query = (supabase.from('vouchers') as any)
        .select('*, promos(name)')
        .eq('outlet_id', outletId)
        .order('created_at', { ascending: false })
      if (promoId) query = query.eq('promo_id', promoId)
      const { data, error } = await query
      if (error) throw error
      return data as VoucherWithPromo[]
    },
    enabled: !!outletId,
  })
}

function generateCode(length = 8): string {
  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
  const bytes = new Uint8Array(length)
  window.crypto.getRandomValues(bytes)
  return Array.from(bytes, (b) => chars[b % chars.length]).join('')
}

export function useGenerateVouchers(outletId: string | null) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async ({
      promoId,
      count,
      usageLimit,
    }: {
      promoId: string
      count: number
      usageLimit: number | null
    }) => {
      const codes = new Set<string>()
      while (codes.size < count) codes.add(generateCode())

      const rows = Array.from(codes).map((code) => ({
        promo_id: promoId,
        outlet_id: outletId,
        code,
        usage_limit: usageLimit,
        usage_count: 0,
        is_active: true,
      }))

      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const { data, error } = await (supabase.from('vouchers') as any)
        .insert(rows)
        .select()
      if (error) throw error
      return data as Voucher[]
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: ['vouchers', outletId] }),
  })
}

export function useToggleVoucher(outletId: string | null) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async ({ id, is_active }: { id: string; is_active: boolean }) => {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const { error } = await (supabase.from('vouchers') as any)
        .update({ is_active })
        .eq('id', id)
      if (error) throw error
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: ['vouchers', outletId] }),
  })
}

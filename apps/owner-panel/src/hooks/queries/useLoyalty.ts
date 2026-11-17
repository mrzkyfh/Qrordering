import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import { sanitizeSearch } from '@/lib/search'
import type { LoyaltyMember, LoyaltyTransaction, LoyaltySummary } from '@/types/database'

export function useLoyaltyMembers(outletId: string | null, search = '') {
  return useQuery({
    queryKey: ['loyalty_members', outletId, search],
    queryFn: async () => {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      let q = (supabase.from('loyalty_members') as any)
        .select('*')
        .eq('outlet_id', outletId)
        .order('created_at', { ascending: false })
      const s = sanitizeSearch(search)
      if (s) q = q.or(`phone.ilike.%${s}%,name.ilike.%${s}%`)
      const { data, error } = await q
      if (error) throw error
      return data as LoyaltyMember[]
    },
    enabled: !!outletId,
  })
}

export function useLoyaltySummary(outletId: string | null) {
  return useQuery({
    queryKey: ['loyalty_summary', outletId],
    queryFn: async () => {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const { data, error } = await (supabase.from('v_loyalty_summary') as any)
        .select('*')
        .eq('outlet_id', outletId)
      if (error) throw error
      return data as LoyaltySummary[]
    },
    enabled: !!outletId,
  })
}

export function useLoyaltyTransactions(memberId: string | null) {
  return useQuery({
    queryKey: ['loyalty_transactions', memberId],
    queryFn: async () => {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const { data, error } = await (supabase.from('loyalty_transactions') as any)
        .select('*')
        .eq('member_id', memberId)
        .order('created_at', { ascending: false })
        .limit(50)
      if (error) throw error
      return data as LoyaltyTransaction[]
    },
    enabled: !!memberId,
  })
}

export function useCreateLoyaltyMember(outletId: string | null) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (payload: { phone: string; name: string }) => {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const { data, error } = await (supabase.from('loyalty_members') as any)
        .insert({ ...payload, outlet_id: outletId })
        .select()
        .single()
      if (error) throw error
      return data as LoyaltyMember
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['loyalty_members', outletId] })
      qc.invalidateQueries({ queryKey: ['loyalty_summary', outletId] })
    },
  })
}

export function useUpdateLoyaltyMember(outletId: string | null) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async ({ id, ...payload }: { id: string; name: string; is_active: boolean }) => {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const { error } = await (supabase.from('loyalty_members') as any)
        .update(payload)
        .eq('id', id)
      if (error) throw error
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['loyalty_members', outletId] })
      qc.invalidateQueries({ queryKey: ['loyalty_summary', outletId] })
    },
  })
}

export function useDeleteLoyaltyMember(outletId: string | null) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (id: string) => {
      // Arsipkan member lewat RPC agar histori poin tidak ikut terhapus oleh
      // FK CASCADE. Data historis tetap tersedia untuk audit dan laporan.
      const { error } = await supabase.rpc('archive_loyalty_member', {
        p_member_id: id,
      })
      if (error) throw error
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['loyalty_members', outletId] })
      qc.invalidateQueries({ queryKey: ['loyalty_summary', outletId] })
    },
  })
}

export function useAdjustPoints(outletId: string | null) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async ({
      member,
      points,
      description,
    }: {
      member: LoyaltyMember
      points: number
      description: string
    }) => {
      const { error } = await supabase.rpc('adjust_loyalty_points', {
        p_member_id: member.id,
        p_points: points,
        p_description: description,
      })
      if (error) throw error
    },
    onSuccess: (_d, vars) => {
      qc.invalidateQueries({ queryKey: ['loyalty_members', outletId] })
      qc.invalidateQueries({ queryKey: ['loyalty_transactions', vars.member.id] })
      qc.invalidateQueries({ queryKey: ['loyalty_summary', outletId] })
    },
  })
}

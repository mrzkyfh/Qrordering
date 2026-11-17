import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import { sanitizeSearch } from '@/lib/search'

export interface CustomerSummary {
  member_id: string
  outlet_id: string
  name: string | null
  phone: string
  tier: string
  points: number
  total_orders: number
  total_spent: number
  last_order_at: string | null
}

export interface CustomerOrder {
  id: string
  order_number: string | number
  created_at: string
  total_amount: number
  status: string
}

export interface CustomerDetail {
  id: string
  name: string | null
  phone: string
  address: string | null
  birthday: string | null
  note: string | null
  tier: string
  points: number
}

export function useCustomerSummary(outletId: string, search = '') {
  return useQuery({
    queryKey: ['customer-summary', outletId, search],
    queryFn: async () => {
      let q = supabase
        .from('v_customer_summary')
        .select('*')
        .eq('outlet_id', outletId)
        .order('total_spent', { ascending: false })
      const safeSearch = sanitizeSearch(search)
      if (safeSearch) {
        const s = `%${safeSearch}%`
        q = q.or(`name.ilike.${s},phone.ilike.${s}`)
      }
      const { data, error } = await q
      if (error) throw error
      return data as CustomerSummary[]
    },
    enabled: !!outletId,
  })
}

export function useCustomerDetail(memberId: string | null) {
  return useQuery({
    queryKey: ['customer-detail', memberId],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('loyalty_members')
        .select('id, name, phone, address, birthday, note, tier, points')
        .eq('id', memberId!)
        .single()
      if (error) throw error
      return data as CustomerDetail
    },
    enabled: !!memberId,
  })
}

export function useCustomerOrders(memberId: string | null) {
  return useQuery({
    queryKey: ['customer-orders', memberId],
    queryFn: async () => {
      // View ini menggabungkan transaksi aktif dan indeks arsip 90 hari.
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const { data, error } = await (supabase as any)
        .from('v_customer_order_history')
        .select('id, order_number, created_at, total_amount, status')
        .eq('loyalty_member_id', memberId!)
        .order('created_at', { ascending: false })
        .limit(50)
      if (error) throw error
      return data as CustomerOrder[]
    },
    enabled: !!memberId,
  })
}

export function useUpdateCustomerCrm() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (input: {
      id: string
      name: string | null
      address: string | null
      birthday: string | null
      note: string | null
    }) => {
      const { error } = await supabase
        .from('loyalty_members')
        .update({ name: input.name, address: input.address, birthday: input.birthday, note: input.note })
        .eq('id', input.id)
      if (error) throw error
    },
    onSuccess: (_, vars) => {
      qc.invalidateQueries({ queryKey: ['customer-detail', vars.id] })
      qc.invalidateQueries({ queryKey: ['customer-summary'] })
    },
  })
}

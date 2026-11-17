import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import { useAuth } from '@/hooks/useAuth'
import type { Expense, ExpenseCategory } from '@/types/database'

// Pengeluaran 1 bulan (opsional semua outlet utk owner) — utk breakdown kategori.
export function useExpensesByCategory(outletId: string | null, month: string) {
  const { isOwner } = useAuth()
  return useQuery({
    queryKey: ['expenses-by-category', outletId, month],
    queryFn: async () => {
      const [y, m] = month.split('-').map(Number)
      const nextYear = m === 12 ? y + 1 : y
      const nextMon = m === 12 ? 1 : m + 1
      const startDate = `${month}-01`
      const endDate = `${nextYear}-${String(nextMon).padStart(2, '0')}-01`
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      let query = (supabase.from('expenses') as any)
        .select('category, amount')
        .gte('expense_date', startDate)
        .lt('expense_date', endDate)
      if (outletId) query = query.eq('outlet_id', outletId)
      const { data, error } = await query
      if (error) throw error
      return data as { category: ExpenseCategory; amount: number }[]
    },
    enabled: !!outletId || isOwner(),
  })
}

export function useExpenses(outletId: string | null, month: string) {
  return useQuery({
    queryKey: ['expenses', outletId, month],
    queryFn: async () => {
      const [y, m] = month.split('-').map(Number)
      const nextYear = m === 12 ? y + 1 : y
      const nextMon = m === 12 ? 1 : m + 1
      const startDate = `${month}-01`
      const endDate = `${nextYear}-${String(nextMon).padStart(2, '0')}-01`
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const { data, error } = await (supabase.from('expenses') as any)
        .select('*')
        .eq('outlet_id', outletId)
        .gte('expense_date', startDate)
        .lt('expense_date', endDate)
        .order('expense_date', { ascending: false })
      if (error) throw error
      return data as Expense[]
    },
    enabled: !!outletId,
  })
}

export function useCreateExpense(outletId: string | null) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (payload: {
      category: ExpenseCategory
      amount: number
      description: string | null
      expense_date: string
    }) => {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const { error } = await (supabase.from('expenses') as any).insert({
        ...payload,
        outlet_id: outletId,
      })
      if (error) throw error
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: ['expenses', outletId] }),
  })
}

export function useUpdateExpense(outletId: string | null) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async ({
      id,
      ...payload
    }: {
      id: string
      category: ExpenseCategory
      amount: number
      description: string | null
      expense_date: string
    }) => {
      // `.select()` WAJIB: tanpa itu, UPDATE yang barisnya disaring RLS membalas
      // 204 No Content — bukan error — sehingga `if (error)` lolos dan UI
      // mengucap "tersimpan" padahal tak ada yang berubah. Dengan .select(),
      // baris kosong = ditolak, dan bisa dilaporkan apa adanya.
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const { data, error } = await (supabase.from('expenses') as any)
        .update(payload)
        .eq('id', id)
        .select('id')
      if (error) throw error
      if (!data || data.length === 0) {
        throw new Error(
          'Pengeluaran tidak tersimpan: Anda tidak berwenang menyunting data ini.',
        )
      }
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: ['expenses', outletId] }),
  })
}

export function useDeleteExpense(outletId: string | null) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (id: string) => {
      // Lihat catatan di useUpdateExpense: DELETE yang disaring RLS juga
      // membalas sukses-tanpa-baris.
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const { data, error } = await (supabase.from('expenses') as any)
        .delete()
        .eq('id', id)
        .select('id')
      if (error) throw error
      if (!data || data.length === 0) {
        throw new Error(
          'Pengeluaran tidak terhapus: Anda tidak berwenang menghapus data ini.',
        )
      }
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: ['expenses', outletId] }),
  })
}

import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import { PROFILE_SELECT_COLUMNS, type Profile } from '@/types/database'

export type StaffRole = 'admin' | 'manajer' | 'kasir'

export function useStaff(
  outletId: string | null = null,
  options?: { enabled?: boolean; includeOwner?: boolean; includeDevice?: boolean },
) {
  const roles = [
    ...(options?.includeOwner ? ['owner'] : []),
    'admin',
    'manajer',
    'kasir',
    ...(options?.includeDevice ? ['pelanggan'] : []),
  ]
  return useQuery({
    queryKey: [
      'staff',
      outletId ?? 'all',
      options?.includeOwner ? 'with-owner' : 'no-owner',
      options?.includeDevice ? 'with-device' : 'no-device',
    ],
    queryFn: async () => {
      let query = supabase
        .from('profiles')
        .select(PROFILE_SELECT_COLUMNS)
        .in('role', roles)
        .order('full_name')

      if (outletId) {
        query = query.eq('outlet_id', outletId)
      }

      const { data, error } = await query
      if (error) throw error
      return data as Profile[]
    },
    enabled: options?.enabled !== false,
  })
}

export function useCreateStaff() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (payload: {
      // Staff login pakai PIN (clock-in). Email sintetis di-generate otomatis.
      // Khusus admin/manajer: email+password opsional untuk akses web panel.
      full_name: string
      role: StaffRole
      outlet_id: string | null
      phone?: string | null
      pin: string
      email?: string | null
      password?: string | null
    }) => {
      const { data, error } = await supabase.functions.invoke('create-staff', {
        body: payload,
      })
      // Extract actual message from edge function error response.
      // `context` bisa Response (FunctionsHttpError), Error (FunctionsRelayError),
      // atau undefined (FunctionsFetchError) — handle semua case dengan aman.
      if (error) {
        const ctx = (error as { context?: unknown }).context
        let bodyMsg: string | null = null
        if (ctx instanceof Response) {
          try {
            const parsed = await ctx.clone().json()
            bodyMsg = parsed?.error ?? parsed?.message ?? null
          } catch {
            try { bodyMsg = await ctx.clone().text() } catch { bodyMsg = null }
          }
        }
        // Khusus: kalau function belum di-deploy
        if (error.message?.includes('Failed to send') || error.message?.includes('NOT_FOUND')) {
          throw new Error('Edge function create-staff belum di-deploy ke Supabase. Jalankan: supabase functions deploy create-staff')
        }
        throw new Error(bodyMsg ?? error.message ?? 'Terjadi kesalahan saat membuat staff')
      }
      if (data?.error) throw new Error(data.error)
      return data
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: ['staff'] }),
  })
}

/**
 * Membuat "Akun Perangkat" per cabang (email+password) sebagai gerbang login
 * di perangkat kasir. Role dipaksa 'pelanggan' di server & disembunyikan dari
 * daftar clock-in. Hanya owner/admin.
 */
export function useCreateDevice() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (payload: {
      full_name?: string
      email: string
      password: string
      outlet_id: string
    }) => {
      const { data, error } = await supabase.functions.invoke('create-staff', {
        body: { ...payload, is_device: true },
      })
      if (error) {
        const ctx = (error as { context?: unknown }).context
        let bodyMsg: string | null = null
        if (ctx instanceof Response) {
          try {
            const parsed = await ctx.clone().json()
            bodyMsg = parsed?.error ?? parsed?.message ?? null
          } catch {
            try { bodyMsg = await ctx.clone().text() } catch { bodyMsg = null }
          }
        }
        throw new Error(bodyMsg ?? error.message ?? 'Gagal membuat akun perangkat')
      }
      if (data?.error) throw new Error(data.error)
      return data
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: ['staff'] }),
  })
}

export function useChangeDevicePassword() {
  return useMutation({
    mutationFn: async ({ userId, password }: { userId: string; password: string }) => {
      const { data, error } = await supabase.functions.invoke('change-device-password', {
        body: { user_id: userId, password },
      })
      if (error) {
        const ctx = (error as { context?: unknown }).context
        let bodyMsg: string | null = null
        if (ctx instanceof Response) {
          try {
            const parsed = await ctx.clone().json()
            bodyMsg = parsed?.error ?? parsed?.message ?? null
          } catch {
            try { bodyMsg = await ctx.clone().text() } catch { bodyMsg = null }
          }
        }
        throw new Error(bodyMsg ?? error.message ?? 'Gagal mengubah password cabang')
      }
      if (data?.error) throw new Error(data.error)
      return data
    },
  })
}

export function useChangeStaffPassword() {
  return useMutation({
    mutationFn: async ({ userId, password }: { userId: string; password: string }) => {
      const { data, error } = await supabase.functions.invoke('change-staff-password', {
        body: { user_id: userId, password },
      })
      if (error) {
        const ctx = (error as { context?: unknown }).context
        let bodyMsg: string | null = null
        if (ctx instanceof Response) {
          try {
            const parsed = await ctx.clone().json()
            bodyMsg = parsed?.error ?? parsed?.message ?? null
          } catch {
            try { bodyMsg = await ctx.clone().text() } catch { bodyMsg = null }
          }
        }
        throw new Error(bodyMsg ?? error.message ?? 'Gagal mereset password staf')
      }
      if (data?.error) throw new Error(data.error)
      return data
    },
  })
}

export function useUpdateStaff() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async ({
      id,
      updates,
    }: {
      id: string
      updates: Partial<Pick<Profile, 'full_name' | 'role' | 'outlet_id' | 'phone' | 'is_active' | 'can_refund'>>
    }) => {
      const { error } = await supabase.rpc('update_staff_profile', {
        p_target: id,
        p_patch: updates,
      })
      if (error) throw error
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: ['staff'] }),
  })
}

export function useDeleteStaff() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (userId: string) => {
      const { error } = await supabase.rpc('delete_staff_user', { p_user_id: userId })
      if (error) throw new Error(error.message)
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: ['staff'] }),
  })
}

/**
 * Menetapkan (set/reset) PIN seorang staf — tunduk hierarki di server
 * (set_staff_pin): hanya boleh untuk role di level sendiri ke bawah & outlet
 * yang sama (kecuali owner).
 */
export function useSetStaffPin() {
  return useMutation({
    mutationFn: async ({ userId, pin }: { userId: string; pin: string }) => {
      const { error } = await supabase.rpc('set_staff_pin', {
        p_target: userId,
        p_pin: pin,
      })
      if (error) throw new Error(error.message)
    },
  })
}

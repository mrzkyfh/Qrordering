import { useQuery } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'

export interface ErrorLog {
  id: string
  message: string
  stack: string | null
  app_build: number | null
  platform: string | null
  created_at: string
  first_seen_at: string
  last_seen_at: string
  occurrence_count: number
  user_name: string | null
}

/** Log error produksi yang sudah digabung per fingerprint (hanya owner). */
export function useErrorLogs() {
  return useQuery({
    queryKey: ['error-logs'],
    queryFn: async () => {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const { data, error } = await (supabase.from('error_logs') as any)
        .select('id, message, stack, app_build, platform, created_at, first_seen_at, last_seen_at, occurrence_count, profiles:user_id(full_name)')
        .order('last_seen_at', { ascending: false })
        .limit(200)
      if (error) throw error
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      return ((data ?? []) as any[]).map((r) => ({
        id: r.id,
        message: r.message,
        stack: r.stack ?? null,
        app_build: r.app_build ?? null,
        platform: r.platform ?? null,
        created_at: r.created_at,
        first_seen_at: r.first_seen_at ?? r.created_at,
        last_seen_at: r.last_seen_at ?? r.created_at,
        occurrence_count: Number(r.occurrence_count ?? 1),
        user_name: r.profiles?.full_name ?? null,
      })) as ErrorLog[]
    },
  })
}

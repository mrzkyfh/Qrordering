import { useQuery } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import { useAuth } from '@/hooks/useAuth'
import { useOutletContext } from '@/hooks/useOutletContext'
import type { Outlet } from '@/types/database'

export function useOutlet() {
  const { profile, isOwner } = useAuth()
  const { selectedOutletId, setSelectedOutletId } = useOutletContext()

  const isOwnerUser = isOwner()

  // Only owner needs the full outlets list (for the outlet switcher)
  // Admin/manager is locked to their profile.outlet_id
  const { data: outlets = [] } = useQuery({
    queryKey: ['outlets'],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('outlets')
        .select('*')
        .eq('is_active', true)
        .order('name')
      if (error) throw error
      return data as Outlet[]
    },
    enabled: isOwnerUser,
  })

  // Owner: picks from all outlets, falls back to first active
  // Admin/Manager: strictly their assigned outlet_id only (null if not yet assigned)
  const activeOutletId: string | null = isOwnerUser
    ? (selectedOutletId ?? profile?.outlet_id ?? outlets[0]?.id ?? null)
    : (profile?.outlet_id ?? null)

  // Owner: derive activeOutlet from the already-fetched outlets list (no extra round trip)
  // Admin/Manager: outlets query is disabled, so fetch their single outlet separately
  const { data: activeOutlet } = useQuery({
    queryKey: ['outlet', activeOutletId],
    queryFn: async () => {
      if (!activeOutletId) return null
      const { data, error } = await supabase
        .from('outlets')
        .select('*')
        .eq('id', activeOutletId)
        .single()
      if (error) throw error
      return data as Outlet
    },
    enabled: !!activeOutletId && !isOwnerUser,
    initialData: isOwnerUser ? (outlets.find((o) => o.id === activeOutletId) ?? undefined) : undefined,
  })

  return {
    outlets,
    activeOutlet,
    activeOutletId,
    // Only expose the outlet switcher to owners
    setSelectedOutletId: isOwnerUser ? setSelectedOutletId : undefined,
  }
}

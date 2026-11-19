import { useEffect } from 'react'
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
  const { data: outlets = [], isPending: isLoadingOutlets } = useQuery({
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

  const selectedOutlet = isOwnerUser
    ? outlets.find((outlet) => outlet.id === selectedOutletId)
    : undefined
  const profileOutlet = isOwnerUser
    ? outlets.find((outlet) => outlet.id === profile?.outlet_id)
    : undefined

  // Owner: only use an ID that still exists in the active outlet list. This
  // prevents a deleted outlet cached in localStorage/profile from being sent
  // to inserts and Edge Functions.
  const ownerActiveOutlet = selectedOutlet ?? profileOutlet ?? outlets[0]

  // Keep the persisted selection clean after an outlet is deleted and persist
  // the automatic fallback, so every page uses the same valid outlet.
  useEffect(() => {
    if (!isOwnerUser || isLoadingOutlets) return
    const nextId = ownerActiveOutlet?.id ?? null
    if (selectedOutletId !== nextId) setSelectedOutletId(nextId)
  }, [isOwnerUser, isLoadingOutlets, ownerActiveOutlet?.id, selectedOutletId, setSelectedOutletId])

  // Owner: picks from all valid outlets, falls back to the first active one.
  // Admin/Manager: strictly their assigned outlet_id only (null if not yet assigned)
  const activeOutletId: string | null = isOwnerUser
    ? (ownerActiveOutlet?.id ?? null)
    : (profile?.outlet_id ?? null)

  // Owner: derive activeOutlet from the already-fetched outlets list (no extra round trip)
  // Admin/Manager: outlets query is disabled, so fetch their single outlet separately
  const { data: assignedOutlet } = useQuery({
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
  })

  // Do not put the owner outlet in a disabled query with `initialData`: when
  // the outlet list arrives asynchronously that initial value is never
  // refreshed. Derive it directly from the fetched list instead.
  const activeOutlet = isOwnerUser ? ownerActiveOutlet : assignedOutlet

  return {
    outlets,
    activeOutlet,
    activeOutletId,
    isLoadingOutlets,
    // Only expose the outlet switcher to owners
    setSelectedOutletId: isOwnerUser ? setSelectedOutletId : undefined,
  }
}

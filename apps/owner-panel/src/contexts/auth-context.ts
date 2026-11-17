import { createContext } from 'react'
import type { User } from '@supabase/supabase-js'
import type { Profile, UserRole } from '@/types/database'

export interface AuthContextValue {
  user: User | null
  profile: Profile | null
  loading: boolean
  profileReady: boolean
  outletId: string | null
  isOwner: () => boolean
  isAdmin: () => boolean
  hasRole: (roles: UserRole[]) => boolean
  signOut: () => Promise<void>
}

export const AuthContext = createContext<AuthContextValue | null>(null)

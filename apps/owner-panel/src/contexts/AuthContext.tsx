import {
  useEffect,
  useState,
  useCallback,
  type ReactNode,
} from 'react'
import type { Session, User } from '@supabase/supabase-js'
import { supabase } from '@/lib/supabase'
import {
  PROFILE_SELECT_COLUMNS,
  normalizeUserRole,
  userRoleHasAccess,
  type Profile,
  type UserRole,
} from '@/types/database'
import { AuthContext } from '@/contexts/auth-context'

export function AuthProvider({ children }: { children: ReactNode }) {
  const [user, setUser] = useState<User | null>(null)
  const [profile, setProfile] = useState<Profile | null>(null)
  const [loading, setLoading] = useState(true)
  const [profileReady, setProfileReady] = useState(false)

  async function fetchProfile(userId: string) {
    const { data, error } = await supabase
      .from('profiles')
      .select(PROFILE_SELECT_COLUMNS)
      .eq('id', userId)
      .single()
    if (error) {
      console.error('fetchProfile error:', error)
      return null
    }
    return data
  }

  const handleSession = useCallback(async (session: Session | null) => {
    const newUser = session?.user ?? null
    // Mark as loading before async profile fetch to prevent premature ProtectedRoute redirects
    setLoading(true)
    setProfileReady(false)
    setUser(newUser)
    try {
      if (newUser) {
        const p = await fetchProfile(newUser.id)
        setProfile(p)
      } else {
        setProfile(null)
      }
    } catch (err) {
      console.error('handleSession error:', err)
      setProfile(null)
    } finally {
      setLoading(false)
      setProfileReady(true)
    }
  }, [])

  useEffect(() => {
    // Initialize with the current session immediately
    supabase.auth.getSession().then(({ data: { session } }) => {
      handleSession(session)
    }).catch(() => {
      setLoading(false)
      setProfileReady(true)
    })

    // Listen for future auth changes (SIGNED_IN, SIGNED_OUT, TOKEN_REFRESHED)
    const { data: { subscription } } = supabase.auth.onAuthStateChange(
      (event, session) => {
        if (event === 'INITIAL_SESSION') return // handled by getSession above
        // TOKEN_REFRESHED (± tiap jam) tidak mengganti user/profil — cukup
        // perbarui objek user. Memanggil handleSession di sini membuat seluruh
        // panel berkedip ke skeleton (loading=true) + refetch profil tanpa perlu.
        if (event === 'TOKEN_REFRESHED') {
          setUser(session?.user ?? null)
          return
        }
        handleSession(session)
      }
    )

    return () => subscription.unsubscribe()
  }, [handleSession])

  const isOwner = () => profile?.role === 'owner'
  const isAdmin = () =>
    profile ? normalizeUserRole(profile.role) === 'admin' || profile.role === 'owner' : false
  const hasRole = (roles: UserRole[]) =>
    profile ? userRoleHasAccess(profile.role, roles) : false

  async function signOut() {
    await supabase.auth.signOut()
    setUser(null)
    setProfile(null)
  }

  return (
    <AuthContext.Provider
      value={{
        user,
        profile,
        loading,
        profileReady,
        outletId: profile?.outlet_id ?? null,
        isOwner,
        isAdmin,
        hasRole,
        signOut,
      }}
    >
      {children}
    </AuthContext.Provider>
  )
}

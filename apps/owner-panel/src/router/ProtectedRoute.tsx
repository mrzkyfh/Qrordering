import { Link, Navigate } from 'react-router'
import { useAuth } from '@/hooks/useAuth'
import { userRoleHasAccess, type UserRole } from '@/types/database'
import { Skeleton } from '@/components/ui/skeleton'
import { Button } from '@/components/ui/button'

interface ProtectedRouteProps {
  children: React.ReactNode
  allowedRoles: UserRole[]
}

export function ProtectedRoute({ children, allowedRoles }: ProtectedRouteProps) {
  const { user, profile, loading, profileReady, signOut } = useAuth()

  if (loading || !profileReady) {
    return (
      <div className="flex h-screen items-center justify-center">
        <div className="space-y-4 w-64">
          <Skeleton className="h-8 w-full" />
          <Skeleton className="h-4 w-3/4" />
          <Skeleton className="h-4 w-1/2" />
        </div>
      </div>
    )
  }

  if (!user || !profile) {
    return <Navigate to="/login" replace />
  }

  if (!userRoleHasAccess(profile.role, allowedRoles)) {
    const dashboardPath = '/dashboard'
    return (
      <div className="flex min-h-[60vh] flex-col items-center justify-center gap-4 text-center p-4">
        <h1 className="text-4xl font-bold text-destructive">403</h1>
        <p className="text-muted-foreground">
          Anda tidak memiliki akses ke halaman ini.
        </p>
        <div className="flex flex-wrap justify-center gap-2">
          <Button asChild>
            <Link to={dashboardPath}>Kembali ke Dashboard</Link>
          </Button>
          <Button onClick={() => signOut()} variant="outline">
            Keluar
          </Button>
        </div>
      </div>
    )
  }

  return <>{children}</>
}

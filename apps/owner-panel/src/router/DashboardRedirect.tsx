import { Navigate } from 'react-router'
import { useAuth } from '@/hooks/useAuth'
import { Skeleton } from '@/components/ui/skeleton'
import { Button } from '@/components/ui/button'

export function DashboardRedirect() {
  const { profile, loading, profileReady, signOut } = useAuth()

  if (loading || !profileReady) {
    return (
      <div className="p-8 space-y-4">
        <Skeleton className="h-8 w-64" />
        <Skeleton className="h-4 w-full" />
      </div>
    )
  }

  if (!profile) return <Navigate to="/login" replace />
  if (['owner', 'admin', 'manajer', 'kasir'].includes(profile.role)) {
    return <Navigate to="/admin/dashboard" replace />
  }

  return (
    <div className="flex h-[80vh] flex-col items-center justify-center gap-4 text-center p-4">
      <h2 className="text-2xl font-semibold">Akses Terbatas</h2>
      <p className="text-muted-foreground max-w-md">
        Akun Anda terdaftar sebagai <strong className="capitalize">{profile.role}</strong>.
        Akun ini tidak memiliki akses ke dashboard operasional restoran.
      </p>
      <Button onClick={() => signOut()} variant="outline">
        Keluar
      </Button>
    </div>
  )
}

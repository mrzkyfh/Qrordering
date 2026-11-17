import { Store } from 'lucide-react'
import { Link } from 'react-router'
import { useAuth } from '@/hooks/useAuth'
import { Button } from '@/components/ui/button'

interface NoOutletProps {
  message?: string
  description?: string
}

export function NoOutlet({ message, description }: NoOutletProps) {
  const { isOwner } = useAuth()

  const defaultMessage = isOwner()
    ? 'Belum ada outlet aktif'
    : 'Cabang belum di-assign'

  const defaultDescription = isOwner()
    ? 'Buat outlet di halaman Monitoring Cabang terlebih dahulu.'
    : 'Akun kamu belum di-assign ke cabang. Hubungi owner untuk mengatur akses cabang.'

  return (
    <div className="flex h-64 flex-col items-center justify-center gap-3 text-center">
      <div className="flex h-12 w-12 items-center justify-center rounded-full bg-muted">
        <Store className="h-6 w-6 text-muted-foreground" />
      </div>
      <div>
        <p className="font-medium text-foreground">{message ?? defaultMessage}</p>
        <p className="text-sm text-muted-foreground mt-1 max-w-xs">
          {description ?? defaultDescription}
        </p>
      </div>
      {isOwner() && (
        <Button asChild size="sm" variant="outline">
          <Link to="/owner/branches">Kelola Cabang</Link>
        </Button>
      )}
    </div>
  )
}

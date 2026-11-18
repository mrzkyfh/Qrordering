import { useState } from 'react'
import { useNavigate } from 'react-router'
import { ChevronDown, LogOut, User, Store } from 'lucide-react'
import { Button } from '@/components/ui/button'
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from '@/components/ui/dropdown-menu'
import { Avatar, AvatarFallback, AvatarImage } from '@/components/ui/avatar'
import { useAuth } from '@/hooks/useAuth'
import { useOutlet } from '@/hooks/useOutlet'
import { Badge } from '@/components/ui/badge'

export function Header() {
  const { profile, signOut } = useAuth()
  const { outlets, activeOutlet, setSelectedOutletId } = useOutlet()
  const navigate = useNavigate()
  const [signingOut, setSigningOut] = useState(false)

  const initials = profile?.full_name
    ?.split(' ')
    .map((n) => n[0])
    .slice(0, 2)
    .join('')
    .toUpperCase() ?? '??'

  async function handleSignOut() {
    setSigningOut(true)
    try {
      await signOut()
    } catch {
      // ignore
    }
    window.location.replace('/login')
  }

  const roleLabel: Record<string, string> = {
    owner: 'Owner',
    admin: 'Admin',
    manajer: 'Pelayan',
    kasir: 'Pelayan',
    pelanggan: 'Pelanggan',
  }
  const accountDestination =
    profile?.role === 'owner'
      ? { href: '/owner/dashboard', label: 'Dashboard Owner' }
      : profile?.role === 'admin' || profile?.role === 'manajer'
        ? { href: '/admin/settings', label: 'Pengaturan Outlet' }
        : { href: '/dashboard', label: 'Dashboard' }

  return (
    <header className="flex h-16 items-center justify-between border-b bg-white px-5 lg:px-8 shrink-0">
      {/* Left: outlet name */}
      <div className="flex items-center gap-2">
        <Store className="h-4 w-4 text-muted-foreground" />
        {setSelectedOutletId ? (
          <DropdownMenu>
            <DropdownMenuTrigger asChild>
              <Button variant="ghost" size="sm" className="gap-1 font-medium">
                {activeOutlet?.name ?? 'Pilih Outlet'}
                <ChevronDown className="h-3.5 w-3.5" />
              </Button>
            </DropdownMenuTrigger>
            <DropdownMenuContent align="start">
              <DropdownMenuLabel>Pilih Outlet</DropdownMenuLabel>
              <DropdownMenuSeparator />
              {outlets.map((outlet) => (
                <DropdownMenuItem
                  key={outlet.id}
                  onClick={() => setSelectedOutletId(outlet.id)}
                >
                  {outlet.name}
                </DropdownMenuItem>
              ))}
            </DropdownMenuContent>
          </DropdownMenu>
        ) : (
          <span className="text-sm font-medium">{activeOutlet?.name ?? '—'}</span>
        )}
      </div>

      {/* Right: user menu */}
      <DropdownMenu>
        <DropdownMenuTrigger asChild>
          <Button variant="ghost" size="sm" className="gap-2">
            <Avatar className="h-7 w-7">
              <AvatarImage src={profile?.avatar_url ?? undefined} />
              <AvatarFallback className="text-xs">{initials}</AvatarFallback>
            </Avatar>
            <span className="hidden sm:inline text-sm">{profile?.full_name}</span>
            {profile?.role && (
              <Badge variant="secondary" className="hidden sm:inline-flex text-xs">
                {roleLabel[profile.role]}
              </Badge>
            )}
            <ChevronDown className="h-3.5 w-3.5 text-muted-foreground" />
          </Button>
        </DropdownMenuTrigger>
        <DropdownMenuContent align="end" className="w-48">
          <DropdownMenuLabel className="font-normal">
            <p className="font-medium">{profile?.full_name}</p>
            <p className="text-xs text-muted-foreground">{profile?.role}</p>
          </DropdownMenuLabel>
          <DropdownMenuSeparator />
          <DropdownMenuItem onClick={() => navigate(accountDestination.href)}>
            <User className="mr-2 h-4 w-4" />
            {accountDestination.label}
          </DropdownMenuItem>
          <DropdownMenuSeparator />
          <DropdownMenuItem
            onClick={handleSignOut}
            disabled={signingOut}
            className="text-destructive focus:text-destructive"
          >
            <LogOut className="mr-2 h-4 w-4" />
            {signingOut ? 'Keluar...' : 'Keluar'}
          </DropdownMenuItem>
        </DropdownMenuContent>
      </DropdownMenu>
    </header>
  )
}

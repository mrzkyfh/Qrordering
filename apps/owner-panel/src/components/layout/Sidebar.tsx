import { NavLink, useLocation } from 'react-router'
import { useState } from 'react'
import {
  LayoutDashboard,
  Users,
  UtensilsCrossed,
  TableIcon,
  Tag,
  FileBarChart,
  Settings,
  LogOut,
  CreditCard,
  ShoppingBag,
} from 'lucide-react'
import logo from '@/assets/mejaku-icon.svg'
import { cn } from '@/lib/utils'
import { useAuth } from '@/hooks/useAuth'
import { ScrollArea } from '@/components/ui/scroll-area'
import { Button } from '@/components/ui/button'

interface StandaloneNav {
  label: string
  href: string
  icon: React.ElementType
}

const adminGroups: StandaloneNav[] = [
  { label: 'Dashboard', href: '/admin/dashboard', icon: LayoutDashboard },
  { label: 'Produk', href: '/admin/menu', icon: UtensilsCrossed },
  { label: 'Laporan', href: '/admin/reports', icon: FileBarChart },
  { label: 'Pesanan', href: '/admin/orders', icon: ShoppingBag },
  { label: 'Operasional', href: '/admin/qr-codes', icon: TableIcon },
  { label: 'Promosi', href: '/admin/promos', icon: Tag },
  { label: 'Pembayaran', href: '/admin/payments', icon: CreditCard },
  { label: 'SDM', href: '/admin/staff', icon: Users },
  { label: 'Pengaturan', href: '/admin/settings', icon: Settings },
]

const staffGroups: StandaloneNav[] = [
  { label: 'Dashboard', href: '/admin/dashboard', icon: LayoutDashboard },
  { label: 'Pesanan', href: '/admin/orders', icon: ShoppingBag },
]

function StandaloneLink({ item, onNavigate }: { item: StandaloneNav; onNavigate?: () => void }) {
  const location = useLocation()
  const active = location.pathname === item.href
  return (
    <NavLink
      to={item.href}
      onClick={onNavigate}
      className={cn(
        'flex min-h-12 items-center gap-4 rounded-xl px-4 py-3 text-[15px] font-medium transition-colors',
        active
          ? 'bg-sidebar-accent text-sidebar-accent-foreground'
          : 'text-sidebar-foreground hover:bg-sidebar-accent/50 hover:text-sidebar-accent-foreground'
      )}
    >
      <item.icon className="h-4 w-4 shrink-0" />
      <span>{item.label}</span>
    </NavLink>
  )
}

function NavMenu({ groups, onNavigate }: { groups: StandaloneNav[]; onNavigate?: () => void }) {
  return (
    <nav className="space-y-0.5 px-2">
      {groups.map((g) => <StandaloneLink key={g.href} item={g} onNavigate={onNavigate} />)}
    </nav>
  )
}

export function Sidebar({ onNavigate }: { onNavigate?: () => void }) {
  const { signOut, profile } = useAuth()
  const [signingOut, setSigningOut] = useState(false)
  const outletGroups =
    profile?.role === 'owner' || profile?.role === 'admin' || profile?.role === 'manajer'
      ? adminGroups
      : profile?.role === 'kasir'
        ? staffGroups
        : []

  async function handleSignOut() {
    if (signingOut) return
    setSigningOut(true)
    try { await signOut() } catch { /* ignore */ }
    window.location.replace('/login')
  }

  return (
    <aside className="flex h-full w-[268px] shrink-0 flex-col bg-sidebar text-sidebar-foreground border-r border-sidebar-border">
      {/* Logo */}
      <div className="flex h-16 items-center gap-3 px-5 border-b border-sidebar-border">
        <img src={logo} alt="Logo mejaku" className="h-10 w-10 shrink-0" />
        <span className="text-xl font-extrabold text-sidebar-foreground tracking-tight">meja<span className="text-primary">ku</span></span>
      </div>

      <ScrollArea className="flex-1 py-5">
        <NavMenu groups={outletGroups} onNavigate={onNavigate} />
      </ScrollArea>

      {/* Logout */}
      <div className="border-t border-sidebar-border p-2">
        <Button
          type="button"
          variant="ghost"
          onClick={handleSignOut}
          disabled={signingOut}
          className="w-full justify-start gap-3 px-3 text-sidebar-foreground hover:bg-red-50 hover:text-red-600"
        >
          <LogOut className="h-4 w-4 shrink-0" />
          <span>{signingOut ? 'Keluar...' : 'Keluar'}</span>
        </Button>
      </div>
    </aside>
  )
}

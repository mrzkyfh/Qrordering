import { useState } from 'react'
import { NavLink, useLocation } from 'react-router'
import {
  LayoutDashboard,
  Users,
  UtensilsCrossed,
  TableIcon,
  Tag,
  FileBarChart,
  Settings,
  LogOut,
  ChevronDown,
  ChevronUp,
  CreditCard,
  ShoppingBag,
} from 'lucide-react'
import logo from '@/assets/logo.png'
import { cn } from '@/lib/utils'
import { useAuth } from '@/hooks/useAuth'
import { ScrollArea } from '@/components/ui/scroll-area'
import { Button } from '@/components/ui/button'

interface NavItem {
  label: string
  href: string
}

interface NavGroup {
  label: string
  icon: React.ElementType
  items: NavItem[]
}

interface StandaloneNav {
  label: string
  href: string
  icon: React.ElementType
}

const ownerGroups: (NavGroup | StandaloneNav)[] = [
  { label: 'Dashboard', href: '/admin/dashboard', icon: LayoutDashboard },
]

const adminGroups: (NavGroup | StandaloneNav)[] = [
  { label: 'Dashboard', href: '/admin/dashboard', icon: LayoutDashboard },
  {
    label: 'Produk', icon: UtensilsCrossed,
    items: [
      { label: 'Kategori', href: '/admin/categories' },
      { label: 'Menu & Stok Produk', href: '/admin/menu' },
      { label: 'Paket Promo', href: '/admin/bundles' },
      { label: 'Varian & Add-on', href: '/admin/extras' },
    ],
  },
  {
    label: 'Laporan', icon: FileBarChart,
    items: [
      { label: 'Ringkasan Penjualan', href: '/admin/sales-summary' },
      { label: 'Detail Penjualan', href: '/admin/reports' },
      { label: 'Laporan Kategori', href: '/admin/sales-breakdown/kategori' },
      { label: 'Laporan Menu', href: '/admin/sales-breakdown/menu' },
      { label: 'Laporan Void',  href: '/admin/void-report' },
    ],
  },
  {
    label: 'Pesanan', icon: ShoppingBag,
    items: [
      { label: 'Daftar Pesanan', href: '/admin/orders' },
    ],
  },
  {
    label: 'Operasional', icon: TableIcon,
    items: [
      { label: 'Kelola Meja', href: '/admin/tables' },
      { label: 'QR Code', href: '/admin/qr-codes' },
    ],
  },
  {
    label: 'Promosi', icon: Tag,
    items: [{ label: 'Promo', href: '/admin/promos' }],
  },
  {
    label: 'Pembayaran', icon: CreditCard,
    items: [
      { label: 'Metode Pembayaran', href: '/admin/payments' },
      { label: 'Struk', href: '/admin/receipt' },
      { label: 'Cetak Struk & Dapur', href: '/admin/print-stations' },
      { label: 'Biaya', href: '/admin/charges' },
      { label: 'Pajak', href: '/admin/taxes' },
    ],
  },
  {
    label: 'SDM', icon: Users,
    items: [
      { label: 'Staff', href: '/admin/staff' },
    ],
  },
  { label: 'Pengaturan', href: '/admin/settings', icon: Settings },
]

const staffGroups: (NavGroup | StandaloneNav)[] = [
  { label: 'Dashboard', href: '/admin/dashboard', icon: LayoutDashboard },
  {
    label: 'Pesanan', icon: ShoppingBag,
    items: [{ label: 'Daftar Pesanan', href: '/admin/orders' }],
  },
]

function isStandalone(item: NavGroup | StandaloneNav): item is StandaloneNav {
  return 'href' in item
}

function CollapsibleGroup({ group, onNavigate }: { group: NavGroup; onNavigate?: () => void }) {
  const location = useLocation()
  const isAnyActive = group.items.some((i) => location.pathname === i.href)
  const [open, setOpen] = useState(isAnyActive)

  return (
    <div>
      <button
        type="button"
        onClick={() => setOpen((o) => !o)}
        aria-expanded={open}
        className={cn(
          'flex w-full items-center gap-3 rounded-md px-3 py-2 text-sm font-medium transition-colors',
          isAnyActive
            ? 'bg-sidebar-accent text-sidebar-accent-foreground'
            : 'text-sidebar-foreground hover:bg-sidebar-accent/50 hover:text-sidebar-accent-foreground'
        )}
      >
        <group.icon className="h-4 w-4 shrink-0" />
        <span className="flex-1 text-left">{group.label}</span>
        {open ? <ChevronUp className="h-3.5 w-3.5" /> : <ChevronDown className="h-3.5 w-3.5" />}
      </button>

      {open && (
        <div className="mt-0.5 ml-7 space-y-0.5 border-l border-sidebar-border pl-3">
          {group.items.map((item) => {
            const active = location.pathname === item.href
            return (
              <NavLink
                key={item.href}
                to={item.href}
                onClick={onNavigate}
                className={cn(
                  'block rounded-md px-2 py-1.5 text-sm transition-colors',
                  active
                    ? 'bg-sidebar-accent font-medium text-sidebar-accent-foreground'
                    : 'text-sidebar-foreground/80 hover:bg-sidebar-accent/40 hover:text-sidebar-accent-foreground'
                )}
              >
                {item.label}
              </NavLink>
            )
          })}
        </div>
      )}
    </div>
  )
}

function StandaloneLink({ item, onNavigate }: { item: StandaloneNav; onNavigate?: () => void }) {
  const location = useLocation()
  const active = location.pathname === item.href
  return (
    <NavLink
      to={item.href}
      onClick={onNavigate}
      className={cn(
        'flex items-center gap-3 rounded-md px-3 py-2 text-sm font-medium transition-colors',
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

function NavMenu({ groups, onNavigate }: { groups: (NavGroup | StandaloneNav)[]; onNavigate?: () => void }) {
  return (
    <nav className="space-y-0.5 px-2">
      {groups.map((g) =>
        isStandalone(g)
          ? <StandaloneLink key={g.href} item={g} onNavigate={onNavigate} />
          : <CollapsibleGroup key={g.label} group={g} onNavigate={onNavigate} />
      )}
    </nav>
  )
}

export function Sidebar({ onNavigate }: { onNavigate?: () => void }) {
  const { isOwner, signOut, profile } = useAuth()
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
    <aside className="flex h-full w-[276px] shrink-0 flex-col bg-sidebar text-sidebar-foreground border-r border-sidebar-border">
      {/* Logo */}
      <div className="flex h-[72px] items-center gap-3 px-5 border-b border-sidebar-border">
        <img src={logo} alt="QR Ordering" className="h-11 w-11 rounded-full object-cover shrink-0 ring-2 ring-primary/10" />
        <span className="text-lg font-extrabold text-sidebar-foreground tracking-tight">QR Ordering</span>
      </div>

      <ScrollArea className="flex-1 py-5">
        {isOwner() && (
          <>
            <p className="px-4 pb-1 text-xs font-medium uppercase tracking-wider text-sidebar-foreground/50">
              Owner
            </p>
            <NavMenu groups={ownerGroups} onNavigate={onNavigate} />
            <div className="my-3 mx-2 border-t border-sidebar-border" />
            <p className="px-4 pb-1 text-xs font-medium uppercase tracking-wider text-sidebar-foreground/50">
              Outlet
            </p>
          </>
        )}
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

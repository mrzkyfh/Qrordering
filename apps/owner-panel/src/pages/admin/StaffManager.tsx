import { useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import { useOutlet } from '@/hooks/useOutlet'
import { useAuth } from '@/hooks/useAuth'
import { PageHeader } from '@/components/ui/PageHeader'
import { NoOutlet } from '@/components/ui/NoOutlet'
import { DataTable } from '@/components/ui/DataTable'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Dialog, DialogContent, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select'
import { useCreateDevice, useCreateStaff, type StaffRole } from '@/hooks/queries/useStaff'
import { useToast } from '@/hooks/use-toast'
import { humanizeError } from '@/lib/errorMessage'
import { ChefHat, ShieldCheck, Smartphone, UserRound, Users } from 'lucide-react'
import { format } from 'date-fns'
import { id } from 'date-fns/locale'
import {
  PROFILE_SELECT_COLUMNS,
  type Profile,
  type UserRole,
} from '@/types/database'

const ROLE_LABELS: Record<UserRole, string> = {
  owner: 'Owner', admin: 'Admin', manajer: 'Pelayan', kasir: 'Pelayan', pelanggan: 'Pelanggan',
}

const VISIBLE_ROLES: UserRole[] = ['manajer', 'kasir']
const OWNER_VISIBLE_ROLES: UserRole[] = ['owner', 'admin', 'manajer', 'kasir']

function useStaff(outletId: string, roles: UserRole[]) {
  return useQuery({
    queryKey: ['staff', outletId, roles],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('profiles').select(PROFILE_SELECT_COLUMNS)
        .eq('outlet_id', outletId)
        .in('role', roles)
        .order('full_name')
      if (error) throw error
      return data as Profile[]
    },
    enabled: !!outletId,
  })
}

export default function AdminStaffManager() {
  const { activeOutletId, activeOutlet } = useOutlet()
  const { isOwner } = useAuth()
  const roles = isOwner() ? OWNER_VISIBLE_ROLES : VISIBLE_ROLES
  const { data: staff = [], isLoading } = useStaff(activeOutletId ?? '', roles)
  const createStaff = useCreateStaff()
  const createDevice = useCreateDevice()
  const { toast } = useToast()
  const [createOpen, setCreateOpen] = useState(false)
  const [name, setName] = useState('')
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [pin, setPin] = useState('')
  const [role, setRole] = useState<StaffRole>('kasir')
  const [deviceOpen, setDeviceOpen] = useState(false)
  const [deviceName, setDeviceName] = useState('Perangkat Pesanan & Dapur')
  const [deviceEmail, setDeviceEmail] = useState('')
  const [devicePassword, setDevicePassword] = useState('')

  async function submitStaff() {
    if (!activeOutletId || name.trim().length < 2 || !/^\d{4}$/.test(pin)) {
      toast({ title: 'Lengkapi nama dan PIN 4 digit', variant: 'destructive' }); return
    }
    try {
      if (role === 'admin' && (!email.trim() || password.length < 8)) { toast({ title: 'Admin membutuhkan email dan password minimal 8 karakter', variant: 'destructive' }); return }
      await createStaff.mutateAsync({ full_name: name.trim(), role, outlet_id: activeOutletId, pin, email: role === 'admin' ? email.trim() : null, password: role === 'admin' ? password : null })
      toast({ title: 'Pengguna berhasil ditambahkan' }); setCreateOpen(false); setName(''); setEmail(''); setPassword(''); setPin(''); setRole('kasir')
    } catch (error) { toast({ title: 'Gagal menambah pengguna', description: humanizeError(error), variant: 'destructive' }) }
  }

  async function submitDevice() {
    if (!activeOutletId || !deviceEmail.includes('@') || devicePassword.length < 8) {
      toast({ title: 'Isi email valid dan password minimal 8 karakter', variant: 'destructive' }); return
    }
    try {
      await createDevice.mutateAsync({
        full_name: deviceName.trim() || 'Perangkat Pesanan & Dapur',
        email: deviceEmail.trim(),
        password: devicePassword,
        outlet_id: activeOutletId,
      })
      toast({ title: 'Akun perangkat berhasil dibuat', description: 'Gunakan email dan password ini pada layar Aktivasi Perangkat di aplikasi.' })
      setDeviceOpen(false); setDeviceEmail(''); setDevicePassword('')
    } catch (error) {
      toast({ title: 'Gagal membuat akun perangkat', description: humanizeError(error), variant: 'destructive' })
    }
  }

  if (!activeOutletId) return <NoOutlet />

  return (
    <div className="space-y-4">
      <PageHeader title="SDM" subtitle="Kelola pengguna outlet dan tinjau hak akses setiap peran.">
        <Button variant="outline" onClick={() => setDeviceOpen(true)}><Smartphone className="mr-2 h-4 w-4" />Akun Perangkat</Button>
        <Button onClick={() => setCreateOpen(true)}><Users className="mr-2 h-4 w-4" />Tambah pengguna</Button>
      </PageHeader>
      <div className="grid items-start gap-4 xl:grid-cols-[minmax(0,1fr)_360px]">
      <DataTable
        data={staff}
        loading={isLoading}
        getRowKey={(r) => r.id}
        emptyMessage="Belum ada staff terdaftar."
        columns={[
          { key: 'name', header: 'Pengguna', cell: (r) => <div className="flex items-center gap-3"><span className="flex h-9 w-9 items-center justify-center rounded-full bg-[#CCFBF1] font-semibold text-[#115E59]">{r.full_name.trim().charAt(0).toUpperCase()}</span><div><p className="font-medium">{r.full_name}</p><p className="text-xs text-muted-foreground">{r.login_email ?? 'Email tidak tersedia'}</p></div></div> },
          { key: 'role', header: 'Peran', cell: (r) => <Badge variant="outline">{ROLE_LABELS[r.role]}</Badge> },
          { key: 'login', header: 'Terakhir aktif', cell: (r) => r.last_login_at ? format(new Date(r.last_login_at), 'd MMM yyyy, HH:mm', { locale: id }) : 'Belum pernah' },
          { key: 'outlet', header: 'Outlet', cell: () => activeOutlet?.name ?? '—' },
          { key: 'status', header: 'Status', cell: (r) => <span className={r.is_active ? 'rounded-full bg-green-100 px-2.5 py-1 text-xs font-semibold text-green-800' : 'rounded-full bg-gray-200 px-2.5 py-1 text-xs font-semibold text-gray-700'}>{r.is_active ? 'Aktif' : 'Nonaktif'}</span> },
        ]}
      />
      <aside className="admin-card p-6">
        <h2 className="mb-2 text-lg font-bold">Peran dan hak akses</h2>
        <div className="divide-y">
        {[
          { title: 'Admin / Owner', icon: ShieldCheck, text: 'Akses penuh pengaturan, laporan, pengguna, dan operasional outlet.' },
          { title: 'Pelayan / petugas pembayaran', icon: UserRound, text: 'Kelola pesanan, verifikasi pembayaran manual, dan pelayanan meja.' },
          { title: 'Staf dapur', icon: ChefHat, text: 'Lihat antrean dapur dan perbarui status proses pesanan.' },
        ].map(({ title, icon: Icon, text }) => <section key={title} className="py-4 first:pt-2"><div className="flex items-center gap-2"><Icon className="h-4 w-4 text-[#0F766E]" /><h3 className="font-semibold">{title}</h3></div><p className="mt-1 text-sm leading-6 text-muted-foreground">{text}</p></section>)}
        </div>
      </aside>
      </div>
      <Dialog open={createOpen} onOpenChange={setCreateOpen}><DialogContent><DialogHeader><DialogTitle>Tambah pengguna</DialogTitle></DialogHeader><div className="space-y-4"><label className="block"><span className="mb-1.5 block text-sm font-medium">Nama lengkap</span><Input value={name} onChange={(e) => setName(e.target.value)} /></label><label className="block"><span className="mb-1.5 block text-sm font-medium">Peran</span><Select value={role} onValueChange={(value) => setRole(value as StaffRole)}><SelectTrigger><SelectValue /></SelectTrigger><SelectContent><SelectItem value="kasir">Pelayan / petugas pembayaran</SelectItem>{isOwner() && <SelectItem value="admin">Admin</SelectItem>}</SelectContent></Select></label><label className="block"><span className="mb-1.5 block text-sm font-medium">PIN 4 digit</span><Input value={pin} onChange={(e) => setPin(e.target.value.replace(/\D/g, '').slice(0, 4))} inputMode="numeric" maxLength={4} /></label>{role === 'admin' && <><label className="block"><span className="mb-1.5 block text-sm font-medium">Email akses web</span><Input type="email" value={email} onChange={(e) => setEmail(e.target.value)} /></label><label className="block"><span className="mb-1.5 block text-sm font-medium">Password akses web</span><Input type="password" value={password} onChange={(e) => setPassword(e.target.value)} /></label></>}<p className="text-xs text-muted-foreground">Pelayan masuk menggunakan PIN. Admin memakai email dan password untuk akses web.</p></div><DialogFooter><Button variant="outline" onClick={() => setCreateOpen(false)}>Batal</Button><Button onClick={() => void submitStaff()} disabled={createStaff.isPending}>{createStaff.isPending ? 'Menyimpan...' : 'Tambah pengguna'}</Button></DialogFooter></DialogContent></Dialog>
      <Dialog open={deviceOpen} onOpenChange={setDeviceOpen}>
        <DialogContent>
          <DialogHeader><DialogTitle>Akun Perangkat — {activeOutlet?.name ?? 'Outlet'}</DialogTitle></DialogHeader>
          <p className="text-sm text-muted-foreground">Akun ini dipakai satu kali untuk mengaktifkan aplikasi Pesanan QR & Dapur pada perangkat outlet.</p>
          <div className="space-y-4">
            <label className="block"><span className="mb-1.5 block text-sm font-medium">Nama perangkat</span><Input value={deviceName} onChange={(event) => setDeviceName(event.target.value)} /></label>
            <label className="block"><span className="mb-1.5 block text-sm font-medium">Email perangkat</span><Input type="email" placeholder="dapur@restoran.com" value={deviceEmail} onChange={(event) => setDeviceEmail(event.target.value)} /></label>
            <label className="block"><span className="mb-1.5 block text-sm font-medium">Password</span><Input type="password" placeholder="Minimal 8 karakter" value={devicePassword} onChange={(event) => setDevicePassword(event.target.value)} /></label>
          </div>
          <DialogFooter><Button variant="outline" onClick={() => setDeviceOpen(false)}>Batal</Button><Button onClick={() => void submitDevice()} disabled={createDevice.isPending}>{createDevice.isPending ? 'Membuat...' : 'Buat Akun Perangkat'}</Button></DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  )
}

import { useMemo, useState } from 'react'
import { useForm, useWatch } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import { z } from 'zod'
import { format } from 'date-fns'
import { id as idLocale } from 'date-fns/locale'
import { Plus, Pencil, ToggleLeft, ToggleRight, Users, Trash2, KeyRound, Smartphone, LockKeyhole } from 'lucide-react'
import { useStaff, useCreateStaff, useCreateDevice, useChangeDevicePassword, useChangeStaffPassword, useUpdateStaff, useDeleteStaff, useSetStaffPin, type StaffRole } from '@/hooks/queries/useStaff'
import { ConfirmDialog } from '@/components/ui/ConfirmDialog'
import { useOutlets } from '@/hooks/queries/useOutlets'
import { PageHeader } from '@/components/ui/PageHeader'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Skeleton } from '@/components/ui/skeleton'
import {
  Dialog, DialogContent, DialogHeader, DialogTitle, DialogFooter,
} from '@/components/ui/dialog'
import {
  Form, FormControl, FormField, FormItem, FormLabel, FormMessage,
} from '@/components/ui/form'
import {
  Select, SelectContent, SelectItem, SelectTrigger, SelectValue,
} from '@/components/ui/select'
import type { Profile } from '@/types/database'
import { useAuth } from '@/hooks/useAuth'
import { useToast } from '@/hooks/use-toast'
import { humanizeError } from '@/lib/errorMessage'

// Hierarki: owner(4) > admin/manajer(3) > kasir(1).
const ROLE_RANK: Record<string, number> = {
  owner: 4, admin: 3, manajer: 3, kasir: 1,
}
const roleRank = (r?: string | null) => ROLE_RANK[r ?? ''] ?? 0

const ROLE_LABEL: Record<string, string> = {
  owner: 'Owner',
  admin: 'Admin',
  manajer: 'Manajer',
  kasir: 'Kasir',
  pelanggan: 'Perangkat',
}

const ROLE_VARIANT: Record<string, 'default' | 'secondary' | 'outline'> = {
  owner: 'default',
  admin: 'default',
  manajer: 'secondary',
  kasir: 'outline',
  pelanggan: 'outline',
}

function Initials({ name }: { name: string }) {
  const parts = name.trim().split(' ')
  const text = parts.length >= 2
    ? (parts[0][0] + parts[parts.length - 1][0]).toUpperCase()
    : name.slice(0, 2).toUpperCase()
  return (
    <div className="h-8 w-8 rounded-full bg-primary/10 text-primary flex items-center justify-center text-xs font-semibold shrink-0">
      {text}
    </div>
  )
}

// ─── Create Form ──────────────────────────────────────────────────────────────

const createSchema = z.object({
  full_name: z.string().min(2, 'Nama minimal 2 karakter'),
  // Staff login via PIN (clock-in), bukan email. PIN 4 digit (sesuai keypad).
  pin: z.string().regex(/^[0-9]{4}$/, 'PIN harus 4 digit angka'),
  role: z.enum(['admin', 'manajer', 'kasir']),
  outlet_id: z.string().optional(),
  phone: z.string().optional(),
  // Akses web (opsional, untuk admin/manajer).
  email: z.string().optional(),
  password: z.string().optional(),
}).refine(
  (d) => !['kasir', 'manajer'].includes(d.role) || !!d.outlet_id,
  { message: 'Cabang wajib dipilih untuk role Manajer dan Kasir', path: ['outlet_id'] }
).refine(
  (d) => !d.email || /.+@.+\..+/.test(d.email),
  { message: 'Email tidak valid', path: ['email'] }
).refine(
  // Jika email diisi, password wajib min 8 (dan sebaliknya).
  (d) => (!d.email && !d.password) || (!!d.email && (d.password ?? '').length >= 8),
  { message: 'Password akses web minimal 8 karakter', path: ['password'] }
)
type CreateForm = z.infer<typeof createSchema>

function CreateStaffDialog({ open, onClose }: { open: boolean; onClose: () => void }) {
  const create = useCreateStaff()
  const { data: outlets = [] } = useOutlets()
  const { toast } = useToast()

  const form = useForm<CreateForm>({
    resolver: zodResolver(createSchema),
    defaultValues: { full_name: '', pin: '', role: 'kasir', outlet_id: '', phone: '', email: '', password: '' },
  })

  const role = useWatch({ control: form.control, name: 'role' })
  const canWeb = role === 'admin' || role === 'manajer'

  async function onSubmit(values: CreateForm) {
    try {
      await create.mutateAsync({
        full_name: values.full_name,
        role: values.role as StaffRole,
        outlet_id: values.outlet_id || null,
        phone: values.phone || null,
        pin: values.pin,
        email: canWeb && values.email ? values.email : null,
        password: canWeb && values.password ? values.password : null,
      })
      toast({ title: 'Staff berhasil ditambahkan' })
      form.reset()
      onClose()
    } catch (error) {
      toast({ title: 'Gagal menambahkan staff', description: humanizeError(error), variant: 'destructive' })
    }
  }

  return (
    <Dialog open={open} onOpenChange={(o) => { if (!o) { form.reset(); onClose() } }}>
      <DialogContent className="sm:max-w-md">
        <DialogHeader>
          <DialogTitle>Tambah Staff Baru</DialogTitle>
        </DialogHeader>
        <Form {...form}>
          <form onSubmit={form.handleSubmit(onSubmit)} className="space-y-4">
            <FormField control={form.control} name="full_name" render={({ field }) => (
              <FormItem>
                <FormLabel>Nama Lengkap <span className="text-destructive">*</span></FormLabel>
                <FormControl><Input placeholder="Budi Santoso" {...field} /></FormControl>
                <FormMessage />
              </FormItem>
            )} />

            <FormField control={form.control} name="pin" render={({ field }) => (
              <FormItem>
                <FormLabel>PIN <span className="text-destructive">*</span></FormLabel>
                <FormControl>
                  <Input
                    type="password"
                    inputMode="numeric"
                    autoComplete="off"
                    maxLength={4}
                    placeholder="4 digit angka"
                    {...field}
                    onChange={(e) => field.onChange(e.target.value.replace(/\D/g, ''))}
                  />
                </FormControl>
                <p className="text-xs text-muted-foreground">
                  Staff login & clock-in pakai PIN ini (tanpa email).
                </p>
                <FormMessage />
              </FormItem>
            )} />

            <div className="grid grid-cols-2 gap-3">
              <FormField control={form.control} name="role" render={({ field }) => (
                <FormItem>
                  <FormLabel>Role <span className="text-destructive">*</span></FormLabel>
                  <Select onValueChange={field.onChange} value={field.value}>
                    <FormControl>
                      <SelectTrigger><SelectValue placeholder="Pilih role" /></SelectTrigger>
                    </FormControl>
                    <SelectContent>
                      <SelectItem value="admin">Admin</SelectItem>
                      <SelectItem value="manajer">Manajer</SelectItem>
                      <SelectItem value="kasir">Kasir</SelectItem>
                    </SelectContent>
                  </Select>
                  <FormMessage />
                </FormItem>
              )} />
              <FormField control={form.control} name="outlet_id" render={({ field }) => (
                <FormItem>
                  <FormLabel>Cabang</FormLabel>
                  <Select onValueChange={field.onChange} value={field.value}>
                    <FormControl>
                      <SelectTrigger><SelectValue placeholder="Pilih cabang" /></SelectTrigger>
                    </FormControl>
                    <SelectContent>
                      {outlets.map((o) => (
                        <SelectItem key={o.id} value={o.id}>{o.name}</SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                  <FormMessage />
                </FormItem>
              )} />
            </div>

            <FormField control={form.control} name="phone" render={({ field }) => (
              <FormItem>
                <FormLabel>Nomor HP</FormLabel>
                <FormControl><Input placeholder="08xxxxxxxxxx" {...field} /></FormControl>
                <FormMessage />
              </FormItem>
            )} />

            {/* Akses web — hanya untuk Admin & Manajer (opsional) */}
            {canWeb && (
              <div className="rounded-lg border border-dashed p-3 space-y-3">
                <p className="text-xs text-muted-foreground">
                  Akses web panel (opsional). Isi bila role {role} ini
                  perlu login ke web. Sehari-hari di mobile tetap pakai PIN.
                </p>
                <div className="grid grid-cols-2 gap-3">
                  <FormField control={form.control} name="email" render={({ field }) => (
                    <FormItem>
                      <FormLabel>Email web</FormLabel>
                      <FormControl><Input type="email" placeholder="manajer@toko.com" {...field} /></FormControl>
                      <FormMessage />
                    </FormItem>
                  )} />
                  <FormField control={form.control} name="password" render={({ field }) => (
                    <FormItem>
                      <FormLabel>Password web</FormLabel>
                      <FormControl><Input type="password" placeholder="Min. 8 karakter" {...field} /></FormControl>
                      <FormMessage />
                    </FormItem>
                  )} />
                </div>
              </div>
            )}

            {create.error && (
              <p className="text-sm text-destructive">
                {create.error instanceof Error ? create.error.message : 'Terjadi kesalahan'}
              </p>
            )}

            <DialogFooter>
              <Button type="button" variant="outline" onClick={() => { form.reset(); onClose() }}>Batal</Button>
              <Button type="submit" disabled={create.isPending}>
                {create.isPending ? 'Membuat...' : 'Buat Akun Staff'}
              </Button>
            </DialogFooter>
          </form>
        </Form>
      </DialogContent>
    </Dialog>
  )
}

// ─── Create Device Account (gerbang per cabang) ────────────────────────────────

const deviceSchema = z.object({
  full_name: z.string().optional(),
  email: z.string().email('Email tidak valid'),
  password: z.string().min(8, 'Password minimal 8 karakter'),
  outlet_id: z.string().min(1, 'Cabang wajib dipilih'),
})
type DeviceForm = z.infer<typeof deviceSchema>

function CreateDeviceDialog({ open, onClose }: { open: boolean; onClose: () => void }) {
  const create = useCreateDevice()
  const { data: outlets = [] } = useOutlets()
  const { toast } = useToast()

  const form = useForm<DeviceForm>({
    resolver: zodResolver(deviceSchema),
    defaultValues: { full_name: '', email: '', password: '', outlet_id: '' },
  })

  async function onSubmit(values: DeviceForm) {
    try {
      await create.mutateAsync({
        full_name: values.full_name || 'Perangkat Cabang',
        email: values.email,
        password: values.password,
        outlet_id: values.outlet_id,
      })
      toast({ title: 'Akun perangkat berhasil dibuat' })
      form.reset()
      onClose()
    } catch (error) {
      toast({ title: 'Gagal membuat akun perangkat', description: humanizeError(error), variant: 'destructive' })
    }
  }

  return (
    <Dialog open={open} onOpenChange={(o) => { if (!o) { form.reset(); onClose() } }}>
      <DialogContent className="sm:max-w-md">
        <DialogHeader>
          <DialogTitle>Akun Perangkat Cabang</DialogTitle>
        </DialogHeader>
        <p className="text-sm text-muted-foreground">
          Email & password ini dipakai untuk login perangkat kasir <b>sekali</b> per
          cabang (gerbang keamanan). Sehari-hari karyawan cukup pilih nama + PIN.
        </p>
        <Form {...form}>
          <form onSubmit={form.handleSubmit(onSubmit)} className="space-y-4">
            <FormField control={form.control} name="outlet_id" render={({ field }) => (
              <FormItem>
                <FormLabel>Cabang <span className="text-destructive">*</span></FormLabel>
                <Select onValueChange={field.onChange} value={field.value}>
                  <FormControl>
                    <SelectTrigger><SelectValue placeholder="Pilih cabang" /></SelectTrigger>
                  </FormControl>
                  <SelectContent>
                    {outlets.map((o) => (
                      <SelectItem key={o.id} value={o.id}>{o.name}</SelectItem>
                    ))}
                  </SelectContent>
                </Select>
                <FormMessage />
              </FormItem>
            )} />
            <FormField control={form.control} name="email" render={({ field }) => (
              <FormItem>
                <FormLabel>Email <span className="text-destructive">*</span></FormLabel>
                <FormControl><Input type="email" placeholder="jaksel@toko.com" {...field} /></FormControl>
                <FormMessage />
              </FormItem>
            )} />
            <FormField control={form.control} name="password" render={({ field }) => (
              <FormItem>
                <FormLabel>Password <span className="text-destructive">*</span></FormLabel>
                <FormControl><Input type="password" placeholder="Min. 8 karakter" {...field} /></FormControl>
                <FormMessage />
              </FormItem>
            )} />
            {create.error && (
              <p className="text-sm text-destructive">
                {create.error instanceof Error ? create.error.message : 'Terjadi kesalahan'}
              </p>
            )}
            <DialogFooter>
              <Button type="button" variant="outline" onClick={() => { form.reset(); onClose() }}>Batal</Button>
              <Button type="submit" disabled={create.isPending}>
                {create.isPending ? 'Membuat...' : 'Buat Akun Perangkat'}
              </Button>
            </DialogFooter>
          </form>
        </Form>
      </DialogContent>
    </Dialog>
  )
}

// ─── Edit Form ────────────────────────────────────────────────────────────────

const editSchema = z.object({
  full_name: z.string().min(2, 'Nama minimal 2 karakter'),
  role: z.enum(['admin', 'manajer', 'kasir']),
  outlet_id: z.string().optional(),
  phone: z.string().optional(),
})
type EditForm = z.infer<typeof editSchema>

function EditStaffDialog({
  open, onClose, staff,
}: {
  open: boolean; onClose: () => void; staff: Profile
}) {
  const update = useUpdateStaff()
  const { data: outlets = [] } = useOutlets()
  const { toast } = useToast()

  const form = useForm<EditForm>({
    resolver: zodResolver(editSchema),
    values: {
      full_name: staff.full_name,
      role: (staff.role as StaffRole) ?? 'kasir',
      outlet_id: staff.outlet_id ?? '',
      phone: staff.phone ?? '',
    },
  })

  async function onSubmit(values: EditForm) {
    try {
      await update.mutateAsync({
        id: staff.id,
        updates: {
          full_name: values.full_name,
          role: values.role,
          outlet_id: values.outlet_id || null,
          phone: values.phone || null,
        },
      })
      toast({ title: 'Data staff diperbarui' })
      onClose()
    } catch (error) {
      toast({ title: 'Gagal memperbarui staff', description: humanizeError(error), variant: 'destructive' })
    }
  }

  return (
    <Dialog open={open} onOpenChange={(o) => { if (!o) onClose() }}>
      <DialogContent className="sm:max-w-md">
        <DialogHeader>
          <DialogTitle>Edit Staff</DialogTitle>
        </DialogHeader>
        <Form {...form}>
          <form onSubmit={form.handleSubmit(onSubmit)} className="space-y-4">
            <FormField control={form.control} name="full_name" render={({ field }) => (
              <FormItem>
                <FormLabel>Nama Lengkap <span className="text-destructive">*</span></FormLabel>
                <FormControl><Input {...field} /></FormControl>
                <FormMessage />
              </FormItem>
            )} />

            <div className="grid grid-cols-2 gap-3">
              <FormField control={form.control} name="role" render={({ field }) => (
                <FormItem>
                  <FormLabel>Role</FormLabel>
                  <Select onValueChange={field.onChange} value={field.value}>
                    <FormControl>
                      <SelectTrigger><SelectValue /></SelectTrigger>
                    </FormControl>
                    <SelectContent>
                      <SelectItem value="admin">Admin</SelectItem>
                      <SelectItem value="manajer">Manajer</SelectItem>
                      <SelectItem value="kasir">Kasir</SelectItem>
                    </SelectContent>
                  </Select>
                  <FormMessage />
                </FormItem>
              )} />
              <FormField control={form.control} name="outlet_id" render={({ field }) => (
                <FormItem>
                  <FormLabel>Cabang</FormLabel>
                  <Select onValueChange={field.onChange} value={field.value}>
                    <FormControl>
                      <SelectTrigger><SelectValue placeholder="Pilih cabang" /></SelectTrigger>
                    </FormControl>
                    <SelectContent>
                      {outlets.map((o) => (
                        <SelectItem key={o.id} value={o.id}>{o.name}</SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                  <FormMessage />
                </FormItem>
              )} />
            </div>

            <FormField control={form.control} name="phone" render={({ field }) => (
              <FormItem>
                <FormLabel>Nomor HP</FormLabel>
                <FormControl><Input placeholder="08xxxxxxxxxx" {...field} /></FormControl>
                <FormMessage />
              </FormItem>
            )} />

            {update.error && (
              <p className="text-sm text-destructive">
                {update.error instanceof Error ? update.error.message : 'Terjadi kesalahan'}
              </p>
            )}

            <DialogFooter>
              <Button type="button" variant="outline" onClick={onClose}>Batal</Button>
              <Button type="submit" disabled={update.isPending}>
                {update.isPending ? 'Menyimpan...' : 'Simpan Perubahan'}
              </Button>
            </DialogFooter>
          </form>
        </Form>
      </DialogContent>
    </Dialog>
  )
}

// ─── Main Page ────────────────────────────────────────────────────────────────

export default function OwnerStaffManager() {
  const { profile } = useAuth()
  const callerRank = roleRank(profile?.role)
  const { data: staff = [], isLoading } = useStaff(null, { includeOwner: true, includeDevice: true })
  const { data: outlets = [] } = useOutlets()
  const update = useUpdateStaff()
  const deleteStaff = useDeleteStaff()
  const { toast } = useToast()

  const [createOpen, setCreateOpen] = useState(false)
  const [deviceOpen, setDeviceOpen] = useState(false)
  const [editTarget, setEditTarget] = useState<Profile | null>(null)
  const [pinTarget, setPinTarget] = useState<Profile | null>(null)
  const [passwordTarget, setPasswordTarget] = useState<Profile | null>(null)
  const [outletFilter, setOutletFilter] = useState('all')

  const outletMap = useMemo(
    () => Object.fromEntries(outlets.map((o) => [o.id, o.name])),
    [outlets],
  )
  const filteredStaff = useMemo(() => {
    if (outletFilter === 'all') return staff
    if (outletFilter === 'global') return staff.filter((s) => !s.outlet_id)
    return staff.filter((s) => s.outlet_id === outletFilter)
  }, [staff, outletFilter])

  async function handleToggleActive(s: Profile) {
    try {
      await update.mutateAsync({ id: s.id, updates: { is_active: !s.is_active } })
    } catch (error) {
      toast({ title: 'Gagal mengubah status staff', description: humanizeError(error), variant: 'destructive' })
    }
  }

  async function handleToggleRefund(s: Profile) {
    try {
      await update.mutateAsync({ id: s.id, updates: { can_refund: !s.can_refund } })
    } catch (error) {
      toast({ title: 'Gagal mengubah izin refund', description: humanizeError(error), variant: 'destructive' })
    }
  }

  async function handleDeleteStaff(s: Profile) {
    await deleteStaff.mutateAsync(s.id)
    toast({ title: `${s.full_name} dihapus` })
  }

  return (
    <div className="space-y-4">
      <PageHeader title="Manajemen Staff" subtitle="Kelola akun staff dan perangkat cabang">
        <Button variant="outline" onClick={() => setDeviceOpen(true)}>
          <Smartphone className="h-4 w-4 mr-2" />
          Akun Perangkat
        </Button>
        <Button onClick={() => setCreateOpen(true)}>
          <Plus className="h-4 w-4 mr-2" />
          Tambah Staff
        </Button>
      </PageHeader>

      {isLoading ? (
        <div className="space-y-2">
          {Array.from({ length: 5 }).map((_, i) => <Skeleton key={i} className="h-16 w-full rounded-xl" />)}
        </div>
      ) : staff.length === 0 ? (
        <div className="flex flex-col items-center justify-center gap-3 py-16 text-center">
          <div className="flex h-14 w-14 items-center justify-center rounded-full bg-muted">
            <Users className="h-7 w-7 text-muted-foreground" />
          </div>
          <p className="font-medium">Belum ada staff</p>
          <p className="text-sm text-muted-foreground">Klik "Tambah Staff" untuk membuat akun pertama.</p>
          <Button onClick={() => setCreateOpen(true)}>
            <Plus className="h-4 w-4 mr-2" />Tambah Staff
          </Button>
        </div>
      ) : (
        <div className="rounded-xl border overflow-hidden bg-white shadow-sm">
          <div className="flex flex-col gap-2 border-b bg-muted/10 p-4 sm:flex-row sm:items-end sm:justify-between">
            <div className="w-full space-y-1.5 sm:w-72">
              <label htmlFor="staff-outlet-filter" className="text-sm font-medium">
                Filter cabang
              </label>
              <Select value={outletFilter} onValueChange={setOutletFilter}>
                <SelectTrigger id="staff-outlet-filter" aria-label="Filter staff berdasarkan cabang">
                  <SelectValue placeholder="Semua cabang" />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="all">Semua cabang</SelectItem>
                  <SelectItem value="global">Akun global (semua cabang)</SelectItem>
                  {outlets.map((o) => (
                    <SelectItem key={o.id} value={o.id}>{o.name}</SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>
            <p className="text-sm text-muted-foreground" aria-live="polite">
              Menampilkan {filteredStaff.length} dari {staff.length} akun
            </p>
          </div>
          <div className="overflow-x-auto">
          <table className="w-full text-sm min-w-[640px]">
            <thead className="border-b bg-muted/30">
              <tr>
                <th className="text-left px-4 py-3 font-medium text-muted-foreground">Nama</th>
                <th className="text-left px-4 py-3 font-medium text-muted-foreground">Role</th>
                <th className="text-left px-4 py-3 font-medium text-muted-foreground">Cabang</th>
                <th className="text-left px-4 py-3 font-medium text-muted-foreground">Email Login</th>
                <th className="text-left px-4 py-3 font-medium text-muted-foreground">Telepon</th>
                <th className="text-left px-4 py-3 font-medium text-muted-foreground">Login Terakhir</th>
                <th className="text-left px-4 py-3 font-medium text-muted-foreground">Status</th>
                <th className="text-left px-4 py-3 font-medium text-muted-foreground">Akses Refund</th>
                <th className="px-4 py-3" />
              </tr>
            </thead>
            <tbody className="divide-y">
              {filteredStaff.map((s) => (
                <tr key={s.id} className="hover:bg-muted/20 transition-colors">
                  <td className="px-4 py-3">
                    <div className="flex items-center gap-2.5">
                      <Initials name={s.full_name} />
                      <span className="font-medium">{s.full_name}</span>
                    </div>
                  </td>
                  <td className="px-4 py-3">
                    <Badge variant={ROLE_VARIANT[s.role] ?? 'outline'}>
                      {ROLE_LABEL[s.role] ?? s.role}
                    </Badge>
                  </td>
                  <td className="px-4 py-3 text-muted-foreground">
                    {s.outlet_id ? (outletMap[s.outlet_id] ?? '—') : <span className="italic">Semua cabang</span>}
                  </td>
                  <td className="px-4 py-3 text-muted-foreground">
                    {s.login_email ?? '—'}
                  </td>
                  <td className="px-4 py-3 text-muted-foreground">{s.phone ?? '—'}</td>
                  <td className="px-4 py-3 text-muted-foreground">
                    {s.last_login_at
                      ? format(new Date(s.last_login_at), 'd MMM yyyy, HH:mm', { locale: idLocale })
                      : 'Belum pernah'}
                  </td>
                  <td className="px-4 py-3">
                    <Badge variant={s.is_active ? 'default' : 'secondary'}>
                      {s.is_active ? 'Aktif' : 'Nonaktif'}
                    </Badge>
                  </td>
                  <td className="px-4 py-3">
                    {s.role === 'pelanggan' ? (
                      <span className="text-muted-foreground">—</span>
                    ) : (
                      <Button
                        type="button"
                        variant="ghost"
                        size="sm"
                        onClick={() => handleToggleRefund(s)}
                        disabled={update.isPending}
                        aria-label={`${s.can_refund ? 'Cabut' : 'Beri'} izin refund ${s.full_name}`}
                        aria-pressed={s.can_refund}
                        className="h-8 gap-1.5 px-2"
                      >
                        {s.can_refund
                          ? <ToggleRight className="h-5 w-5 text-primary" />
                          : <ToggleLeft className="h-5 w-5 text-muted-foreground" />}
                        <span className={s.can_refund ? 'text-foreground' : 'text-muted-foreground'}>
                          {s.can_refund ? 'Boleh' : 'Tidak'}
                        </span>
                      </Button>
                    )}
                  </td>
                  <td className="px-4 py-3">
                    <div className="flex items-center gap-1 justify-end">
                      <Button
                        type="button"
                        variant="ghost"
                        size="icon-sm"
                        onClick={() => handleToggleActive(s)}
                        disabled={update.isPending}
                        aria-label={`${s.is_active ? 'Nonaktifkan' : 'Aktifkan'} staff ${s.full_name}`}
                        aria-pressed={s.is_active}
                        className="text-muted-foreground hover:text-foreground"
                      >
                        {s.is_active
                          ? <ToggleRight className="h-4 w-4 text-primary" />
                          : <ToggleLeft className="h-4 w-4" />}
                      </Button>
                      {s.role === 'pelanggan' ? (
                        <Button
                          type="button"
                          variant="ghost"
                          size="icon-sm"
                          onClick={() => setPasswordTarget(s)}
                          aria-label={`Ubah password perangkat ${s.full_name}`}
                          className="text-muted-foreground hover:text-foreground"
                        >
                          <LockKeyhole className="h-4 w-4" />
                        </Button>
                      ) : callerRank >= roleRank(s.role) && (
                        <Button
                          type="button"
                          variant="ghost"
                          size="icon-sm"
                          onClick={() => setPinTarget(s)}
                          aria-label={`Atur PIN ${s.full_name}`}
                          className="text-muted-foreground hover:text-foreground"
                        >
                          <KeyRound className="h-4 w-4" />
                        </Button>
                      )}
                      {s.role !== 'owner' && s.role !== 'pelanggan' && callerRank > roleRank(s.role) && s.login_email && (
                        <Button
                          type="button"
                          variant="ghost"
                          size="icon-sm"
                          onClick={() => setPasswordTarget(s)}
                          aria-label={`Reset password web ${s.full_name}`}
                          className="text-muted-foreground hover:text-foreground"
                        >
                          <LockKeyhole className="h-4 w-4" />
                        </Button>
                      )}
                      <Button
                        type="button"
                        variant="ghost"
                        size="icon-sm"
                        onClick={() => setEditTarget(s)}
                        aria-label={`Edit staff ${s.full_name}`}
                        className="text-muted-foreground hover:text-foreground"
                      >
                        <Pencil className="h-4 w-4" />
                      </Button>
                      <ConfirmDialog
                        title={`Hapus ${s.full_name}?`}
                        description="Akun staff akan dihapus permanen dari sistem dan tidak dapat dikembalikan."
                        confirmLabel="Hapus Permanen"
                        destructive
                        onConfirm={() => handleDeleteStaff(s)}
                        trigger={
                          <Button
                            type="button"
                            variant="ghost"
                            size="icon-sm"
                            className="text-muted-foreground hover:bg-destructive/10 hover:text-destructive"
                            aria-label={`Hapus permanen staff ${s.full_name}`}
                          >
                            <Trash2 className="h-4 w-4" />
                          </Button>
                        }
                      />
                    </div>
                  </td>
                </tr>
              ))}
              {filteredStaff.length === 0 && (
                <tr>
                  <td colSpan={9} className="px-4 py-12 text-center">
                    <p className="font-medium">Tidak ada akun pada cabang ini</p>
                    <p className="mt-1 text-sm text-muted-foreground">
                      Pilih cabang lain atau tampilkan kembali seluruh akun.
                    </p>
                    <Button
                      type="button"
                      variant="outline"
                      size="sm"
                      className="mt-4"
                      onClick={() => setOutletFilter('all')}
                    >
                      Tampilkan semua cabang
                    </Button>
                  </td>
                </tr>
              )}
            </tbody>
          </table>
          </div>
        </div>
      )}

      <CreateStaffDialog open={createOpen} onClose={() => setCreateOpen(false)} />
      <CreateDeviceDialog open={deviceOpen} onClose={() => setDeviceOpen(false)} />
      {editTarget && (
        <EditStaffDialog
          open={!!editTarget}
          onClose={() => setEditTarget(null)}
          staff={editTarget}
        />
      )}
      {pinTarget && (
        <SetPinDialog
          open={!!pinTarget}
          onClose={() => setPinTarget(null)}
          staff={pinTarget}
        />
      )}
      {passwordTarget && (
        <ChangeDevicePasswordDialog
          open={!!passwordTarget}
          onClose={() => setPasswordTarget(null)}
          account={passwordTarget}
        />
      )}
    </div>
  )
}

function ChangeDevicePasswordDialog({
  open, onClose, account,
}: {
  open: boolean
  onClose: () => void
  account: Profile
}) {
  const changeDevice = useChangeDevicePassword()
  const changeStaff = useChangeStaffPassword()
  const change = account.role === 'pelanggan' ? changeDevice : changeStaff
  const [password, setPassword] = useState('')
  const [confirm, setConfirm] = useState('')
  const [error, setError] = useState<string | null>(null)

  function reset() {
    setPassword('')
    setConfirm('')
    setError(null)
  }

  async function onSubmit(e: React.FormEvent) {
    e.preventDefault()
    setError(null)
    if (password.length < 8) {
      setError('Password minimal 8 karakter')
      return
    }
    if (password !== confirm) {
      setError('Konfirmasi password tidak cocok')
      return
    }
    try {
      await change.mutateAsync({ userId: account.id, password })
      reset()
      onClose()
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Gagal mengubah password')
    }
  }

  return (
    <Dialog open={open} onOpenChange={(o) => { if (!o) { reset(); onClose() } }}>
      <DialogContent className="sm:max-w-sm">
        <DialogHeader>
          <DialogTitle>{account.role === 'pelanggan' ? 'Ubah Password Perangkat' : 'Reset Password Web'} — {account.full_name}</DialogTitle>
        </DialogHeader>
        <form onSubmit={onSubmit} className="space-y-4">
          <p className="text-sm text-muted-foreground">
            {account.role === 'pelanggan'
              ? 'Password ini digunakan perangkat kasir cabang saat login.'
              : 'Password baru akan digunakan staf saat masuk ke Owner Panel.'}
            {' '}Password lama tidak perlu diketahui.
          </p>
          <div className="space-y-2">
            <label className="text-sm font-medium">Password Baru</label>
            <Input
              type="password"
              autoComplete="new-password"
              minLength={8}
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              placeholder="Minimal 8 karakter"
            />
          </div>
          <div className="space-y-2">
            <label className="text-sm font-medium">Konfirmasi Password</label>
            <Input
              type="password"
              autoComplete="new-password"
              minLength={8}
              value={confirm}
              onChange={(e) => setConfirm(e.target.value)}
              placeholder="Ulangi password baru"
            />
          </div>
          {error && <p className="text-sm text-destructive">{error}</p>}
          <DialogFooter>
            <Button type="button" variant="outline" onClick={() => { reset(); onClose() }}>
              Batal
            </Button>
            <Button type="submit" disabled={change.isPending}>
              {change.isPending ? 'Menyimpan...' : 'Simpan Password'}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  )
}

// ─── Set PIN Dialog ───────────────────────────────────────────────────────────

function SetPinDialog({
  open, onClose, staff,
}: {
  open: boolean; onClose: () => void; staff: Profile
}) {
  const setPin = useSetStaffPin()
  const [pin, setPin1] = useState('')
  const [confirm, setConfirm] = useState('')
  const [err, setErr] = useState<string | null>(null)

  async function onSubmit(e: React.FormEvent) {
    e.preventDefault()
    setErr(null)
    if (!/^[0-9]{4}$/.test(pin)) {
      setErr('PIN harus 4 digit angka')
      return
    }
    if (pin !== confirm) {
      setErr('Konfirmasi PIN tidak cocok')
      return
    }
    try {
      await setPin.mutateAsync({ userId: staff.id, pin })
      onClose()
    } catch (e) {
      setErr(e instanceof Error ? e.message : 'Gagal menyimpan PIN')
    }
  }

  return (
    <Dialog open={open} onOpenChange={(o) => { if (!o) onClose() }}>
      <DialogContent className="sm:max-w-sm">
        <DialogHeader>
          <DialogTitle>Atur PIN — {staff.full_name}</DialogTitle>
        </DialogHeader>
        <form onSubmit={onSubmit} className="space-y-4">
          <p className="text-sm text-muted-foreground">
            PIN 4 digit untuk login (clock-in) & persetujuan void/refund.
            Menetapkan PIN baru akan menimpa PIN lama staf ini.
          </p>
          <div className="space-y-2">
            <label className="text-sm font-medium">PIN Baru</label>
            <Input
              type="password" inputMode="numeric" autoComplete="off"
              maxLength={4} placeholder="4 digit"
              value={pin}
              onChange={(e) => setPin1(e.target.value.replace(/\D/g, ''))}
            />
          </div>
          <div className="space-y-2">
            <label className="text-sm font-medium">Konfirmasi PIN</label>
            <Input
              type="password" inputMode="numeric" autoComplete="off"
              maxLength={4} placeholder="Ulangi PIN"
              value={confirm}
              onChange={(e) => setConfirm(e.target.value.replace(/\D/g, ''))}
            />
          </div>
          {err && <p className="text-sm text-destructive">{err}</p>}
          <DialogFooter>
            <Button type="button" variant="outline" onClick={onClose}>Batal</Button>
            <Button type="submit" disabled={setPin.isPending}>
              {setPin.isPending ? 'Menyimpan...' : 'Simpan PIN'}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  )
}

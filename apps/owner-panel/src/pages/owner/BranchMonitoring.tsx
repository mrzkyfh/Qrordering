import { useState, useCallback } from 'react'
import { useForm } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import { z } from 'zod'
import { format, startOfDay, endOfDay } from 'date-fns'
import { id as idLocale } from 'date-fns/locale'
import { Plus, Pencil, Trash2, ToggleLeft, ToggleRight, Store, Users, Smartphone } from 'lucide-react'
import { useOutlets, useCreateOutlet, useUpdateOutlet, useDeleteOutlet } from '@/hooks/queries/useOutlets'
import { useDailySales } from '@/hooks/queries/useSales'
import { useLowStock } from '@/hooks/queries/useIngredients'
import { useStaff } from '@/hooks/queries/useStaff'
import { PageHeader } from '@/components/ui/PageHeader'
import { CurrencyDisplay } from '@/components/ui/CurrencyDisplay'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Skeleton } from '@/components/ui/skeleton'
import {
  Dialog, DialogContent, DialogHeader, DialogTitle, DialogFooter,
} from '@/components/ui/dialog'
import {
  AlertDialog, AlertDialogAction, AlertDialogCancel, AlertDialogContent,
  AlertDialogDescription, AlertDialogFooter, AlertDialogHeader, AlertDialogTitle,
} from '@/components/ui/alert-dialog'
import {
  Form, FormControl, FormField, FormItem, FormLabel, FormMessage,
} from '@/components/ui/form'
import {
  Sheet, SheetContent, SheetHeader, SheetTitle,
} from '@/components/ui/sheet'
import { useToast } from '@/hooks/use-toast'
import { humanizeError } from '@/lib/errorMessage'
import type { Outlet, Profile } from '@/types/database'
import type { DateRange } from '@/components/ui/DateRangePicker'

function getTodayRange(): DateRange {
  return { from: startOfDay(new Date()), to: endOfDay(new Date()) }
}

const outletSchema = z.object({
  name: z.string().min(2, 'Nama minimal 2 karakter'),
  city: z.string().optional(),
  address: z.string().optional(),
  phone: z.string().optional(),
  tax_percent: z.string().refine(
    (value) => value.trim() === '' || (Number.isFinite(Number(value)) && Number(value) >= 0 && Number(value) <= 100),
    'Pajak harus antara 0 dan 100%',
  ),
  service_charge_percent: z.string().refine(
    (value) => value.trim() === '' || (Number.isFinite(Number(value)) && Number(value) >= 0 && Number(value) <= 100),
    'Service charge harus antara 0 dan 100%',
  ),
})
type OutletForm = z.infer<typeof outletSchema>

const ACCOUNT_ROLE_LABEL: Record<Profile['role'], string> = {
  owner: 'Owner',
  admin: 'Admin',
  manajer: 'Manajer',
  kasir: 'Kasir',
  pelanggan: 'Perangkat',
}

function OutletDetail({ outlet, accounts }: { outlet: Outlet; accounts: Profile[] }) {
  const todayRange = getTodayRange()
  const { data: sales = [] } = useDailySales(outlet.id, todayRange)
  const { data: lowStock = [] } = useLowStock(outlet.id)
  const omzet = sales.reduce((s, d) => s + d.gross_revenue, 0)
  const transaksi = sales.reduce((s, d) => s + d.total_orders, 0)

  return (
    <div className="space-y-5 mt-2">
      <div className="grid grid-cols-2 gap-3">
        <div className="rounded-lg border p-3">
          <p className="text-xs text-muted-foreground">Omzet Hari Ini</p>
          <p className="text-xl font-bold mt-1"><CurrencyDisplay value={omzet} /></p>
        </div>
        <div className="rounded-lg border p-3">
          <p className="text-xs text-muted-foreground">Transaksi</p>
          <p className="text-xl font-bold mt-1">{transaksi}</p>
        </div>
      </div>

      <div className="space-y-1 text-sm">
        {outlet.address && <div className="flex gap-2"><span className="text-muted-foreground w-20 shrink-0">Alamat</span><span>{outlet.address}</span></div>}
        {outlet.city && <div className="flex gap-2"><span className="text-muted-foreground w-20 shrink-0">Kota</span><span>{outlet.city}</span></div>}
        {outlet.phone && <div className="flex gap-2"><span className="text-muted-foreground w-20 shrink-0">Telepon</span><span>{outlet.phone}</span></div>}
        <div className="flex gap-2"><span className="text-muted-foreground w-20 shrink-0">Pajak</span><span>{outlet.settings?.tax_percent ?? 0}%</span></div>
        <div className="flex gap-2"><span className="text-muted-foreground w-20 shrink-0">Service</span><span>{outlet.settings?.service_charge_percent ?? 0}%</span></div>
        <div className="flex gap-2"><span className="text-muted-foreground w-20 shrink-0">Dibuat</span><span>{format(new Date(outlet.created_at), 'd MMM yyyy')}</span></div>
      </div>

      <div>
        <div className="flex items-center justify-between mb-2">
          <p className="text-sm font-medium">Akun Cabang ({accounts.length})</p>
          <span className="text-xs text-muted-foreground">
            {accounts.filter((account) => account.is_active).length} aktif
          </span>
        </div>
        {accounts.length === 0 ? (
          <div className="rounded-lg border border-dashed p-4 text-center text-sm text-muted-foreground">
            Belum ada akun yang terhubung ke cabang ini.
          </div>
        ) : (
          <div className="divide-y rounded-lg border">
            {accounts.map((account) => (
              <div key={account.id} className="flex items-center gap-3 p-3">
                {account.role === 'pelanggan'
                  ? <Smartphone className="h-4 w-4 text-muted-foreground shrink-0" />
                  : <Users className="h-4 w-4 text-muted-foreground shrink-0" />}
                <div className="min-w-0 flex-1">
                  <p className="text-sm font-medium truncate">{account.full_name || 'Tanpa nama'}</p>
                  <p className="text-xs text-muted-foreground">
                    {ACCOUNT_ROLE_LABEL[account.role]} · {account.role === 'pelanggan'
                      ? (account.device_last_seen_at
                        ? `Aktif ${format(new Date(account.device_last_seen_at), 'd MMM yyyy, HH:mm', { locale: idLocale })}`
                        : 'Belum mengirim heartbeat')
                      : (account.last_login_at
                        ? `Login ${format(new Date(account.last_login_at), 'd MMM yyyy, HH:mm', { locale: idLocale })}`
                        : 'Belum pernah login')}
                  </p>
                  {account.login_email && (
                    <p className="text-xs text-muted-foreground truncate">{account.login_email}</p>
                  )}
                </div>
                <Badge variant={account.is_active ? 'default' : 'secondary'}>
                  {account.is_active ? 'Aktif' : 'Nonaktif'}
                </Badge>
              </div>
            ))}
          </div>
        )}
      </div>

      <div>
        <p className="text-sm font-medium mb-2">Stok Kritis ({lowStock.length})</p>
        {lowStock.length === 0
          ? <p className="text-sm text-muted-foreground">Semua stok aman</p>
          : (
            <div className="space-y-1">
              {lowStock.slice(0, 6).map((item) => (
                <div key={item.ingredient_id} className="flex justify-between text-sm">
                  <span>{item.name}</span>
                  <span className="text-muted-foreground">{item.stock_qty} {item.unit}</span>
                </div>
              ))}
              {lowStock.length > 6 && <p className="text-xs text-muted-foreground">+{lowStock.length - 6} lainnya</p>}
            </div>
          )}
      </div>
    </div>
  )
}

function OutletFormDialog({
  open, onClose, editData,
}: {
  open: boolean; onClose: () => void; editData?: Outlet | null
}) {
  const create = useCreateOutlet()
  const update = useUpdateOutlet()
  const { toast } = useToast()
  const isEdit = !!editData

  const form = useForm<OutletForm>({
    resolver: zodResolver(outletSchema),
    values: {
      name: editData?.name ?? '',
      city: editData?.city ?? '',
      address: editData?.address ?? '',
      phone: editData?.phone ?? '',
      tax_percent: String(editData?.settings?.tax_percent ?? 0),
      service_charge_percent: String(editData?.settings?.service_charge_percent ?? 0),
    },
  })

  async function onSubmit(values: OutletForm) {
    const payload = {
      name: values.name,
      city: values.city || null,
      address: values.address || null,
      phone: values.phone || null,
      is_active: true,
      settings: {
        ...(editData?.settings ?? {}),
        tax_percent: Number(values.tax_percent) || 0,
        service_charge_percent: Number(values.service_charge_percent) || 0,
        currency: editData?.settings?.currency ?? 'IDR',
        receipt_footer: editData?.settings?.receipt_footer ?? '',
      },
    }
    try {
      if (isEdit && editData) {
        await update.mutateAsync({ id: editData.id, updates: payload })
      } else {
        await create.mutateAsync(payload)
      }
      toast({ title: isEdit ? 'Outlet diperbarui' : 'Outlet ditambahkan' })
      form.reset()
      onClose()
    } catch (error) {
      toast({
        title: 'Gagal menyimpan outlet',
        description: humanizeError(error),
        variant: 'destructive',
      })
    }
  }

  const loading = create.isPending || update.isPending

  return (
    <Dialog open={open} onOpenChange={(o) => { if (!o) { form.reset(); onClose() } }}>
      <DialogContent className="sm:max-w-md">
        <DialogHeader>
          <DialogTitle>{isEdit ? 'Edit Outlet' : 'Tambah Outlet Baru'}</DialogTitle>
        </DialogHeader>
        <Form {...form}>
          <form onSubmit={form.handleSubmit(onSubmit)} className="space-y-4">
            <FormField control={form.control} name="name" render={({ field }) => (
              <FormItem>
                <FormLabel>Nama Outlet <span className="text-destructive">*</span></FormLabel>
                <FormControl><Input placeholder="Contoh: Kebab 420 Pusat" {...field} /></FormControl>
                <FormMessage />
              </FormItem>
            )} />

            <div className="grid grid-cols-2 gap-3">
              <FormField control={form.control} name="city" render={({ field }) => (
                <FormItem>
                  <FormLabel>Kota</FormLabel>
                  <FormControl><Input placeholder="Jakarta" {...field} /></FormControl>
                  <FormMessage />
                </FormItem>
              )} />
              <FormField control={form.control} name="phone" render={({ field }) => (
                <FormItem>
                  <FormLabel>Telepon</FormLabel>
                  <FormControl><Input placeholder="08xxxxxxxxxx" {...field} /></FormControl>
                  <FormMessage />
                </FormItem>
              )} />
            </div>

            <FormField control={form.control} name="address" render={({ field }) => (
              <FormItem>
                <FormLabel>Alamat</FormLabel>
                <FormControl><Input placeholder="Jl. Contoh No. 1" {...field} /></FormControl>
                <FormMessage />
              </FormItem>
            )} />

            <div className="grid grid-cols-2 gap-3">
              <FormField control={form.control} name="tax_percent" render={({ field }) => (
                <FormItem>
                  <FormLabel>Pajak (%)</FormLabel>
                  <FormControl><Input type="number" min={0} max={100} step={0.1} {...field} /></FormControl>
                  <FormMessage />
                </FormItem>
              )} />
              <FormField control={form.control} name="service_charge_percent" render={({ field }) => (
                <FormItem>
                  <FormLabel>Service Charge (%)</FormLabel>
                  <FormControl><Input type="number" min={0} max={100} step={0.1} {...field} /></FormControl>
                  <FormMessage />
                </FormItem>
              )} />
            </div>

            <DialogFooter>
              <Button type="button" variant="outline" onClick={() => { form.reset(); onClose() }}>Batal</Button>
              <Button type="submit" disabled={loading}>
                {loading ? 'Menyimpan...' : isEdit ? 'Simpan Perubahan' : 'Buat Outlet'}
              </Button>
            </DialogFooter>
          </form>
        </Form>
      </DialogContent>
    </Dialog>
  )
}

export default function BranchMonitoring() {
  const todayRange = getTodayRange()
  const { data: outlets = [], isLoading } = useOutlets()
  const { data: sales = [] } = useDailySales(null, todayRange)
  const { data: accounts = [] } = useStaff(null, { includeOwner: true, includeDevice: true })
  const updateOutlet = useUpdateOutlet()
  const deleteOutlet = useDeleteOutlet()
  const { toast } = useToast()

  const [selected, setSelected] = useState<Outlet | null>(null)
  const [formOpen, setFormOpen] = useState(false)
  const [editData, setEditData] = useState<Outlet | null>(null)
  const [deleteTarget, setDeleteTarget] = useState<Outlet | null>(null)
  const [deleting, setDeleting] = useState(false)
  const [confirmText, setConfirmText] = useState('')

  function getOutletSales(outletId: string) {
    const ds = sales.filter((s) => s.outlet_id === outletId)
    return {
      omzet: ds.reduce((s, d) => s + d.gross_revenue, 0),
      transaksi: ds.reduce((s, d) => s + d.total_orders, 0),
    }
  }

  function getOutletAccounts(outletId: string) {
    return accounts.filter((account) => account.outlet_id === outletId)
  }

  function handleEdit(outlet: Outlet) {
    setEditData(outlet)
    setFormOpen(true)
  }

  async function handleToggleActive(outlet: Outlet) {
    try {
      await updateOutlet.mutateAsync({ id: outlet.id, updates: { is_active: !outlet.is_active } })
      toast({ title: `Outlet ${outlet.is_active ? 'dinonaktifkan' : 'diaktifkan'}` })
    } catch (error) {
      toast({
        title: 'Gagal mengubah status outlet',
        description: error instanceof Error ? error.message : 'Silakan coba lagi.',
        variant: 'destructive',
      })
    }
  }

  const handleDelete = useCallback(async () => {
    if (!deleteTarget) return
    setDeleting(true)
    try {
      const { staff_deleted } = await deleteOutlet.mutateAsync(deleteTarget.id)
      const name = deleteTarget.name
      setDeleteTarget(null)
      setConfirmText('')
      toast({
        title: `Outlet "${name}" beserta semua datanya dihapus`,
        description: staff_deleted > 0
          ? `${staff_deleted} akun Kasir cabang ini ikut dihapus.`
          : undefined,
      })
    } catch (err) {
      const msg = (err as { message?: string })?.message ?? String(err)
      toast({
        title: 'Gagal menghapus outlet',
        description: msg,
        variant: 'destructive',
      })
    } finally {
      setDeleting(false)
    }
  }, [deleteTarget, deleteOutlet, toast])

  return (
    <div className="space-y-4">
      <PageHeader
        title="Monitoring Cabang"
        subtitle="Kelola dan pantau semua outlet"
      >
        <Button onClick={() => { setEditData(null); setFormOpen(true) }}>
          <Plus className="h-4 w-4 mr-2" />
          Tambah Outlet
        </Button>
      </PageHeader>

      {/* Cards grid */}
      {isLoading ? (
        <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
          {Array.from({ length: 3 }).map((_, i) => <Skeleton key={i} className="h-40 rounded-xl" />)}
        </div>
      ) : outlets.length === 0 ? (
        <div className="flex flex-col items-center justify-center gap-3 py-16 text-center">
          <div className="flex h-14 w-14 items-center justify-center rounded-full bg-muted">
            <Store className="h-7 w-7 text-muted-foreground" />
          </div>
          <p className="font-medium">Belum ada outlet</p>
          <p className="text-sm text-muted-foreground">Klik "Tambah Outlet" untuk membuat cabang pertama.</p>
          <Button onClick={() => { setEditData(null); setFormOpen(true) }}>
            <Plus className="h-4 w-4 mr-2" />Tambah Outlet
          </Button>
        </div>
      ) : (
        <div className="grid items-stretch gap-4 sm:grid-cols-2 lg:grid-cols-3">
          {outlets.map((outlet) => {
            const { omzet, transaksi } = getOutletSales(outlet.id)
            const outletAccounts = getOutletAccounts(outlet.id)
            return (
              <div key={outlet.id} className="h-full rounded-xl border bg-white shadow-sm flex flex-col">
                {/* Header */}
                <div className="flex h-20 items-start justify-between gap-3 p-4 pb-3">
                  <div className="min-w-0 flex-1">
                    <Button
                      type="button"
                      variant="link"
                      className="h-auto w-full min-w-0 justify-start overflow-hidden text-ellipsis whitespace-nowrap p-0 text-left font-semibold"
                      onClick={() => setSelected(outlet)}
                    >
                      {outlet.name}
                    </Button>
                    {outlet.city && <p className="mt-0.5 truncate text-xs text-muted-foreground">{outlet.city}</p>}
                  </div>
                  <Badge className="shrink-0" variant={outlet.is_active ? 'default' : 'secondary'}>
                    {outlet.is_active ? 'Aktif' : 'Nonaktif'}
                  </Badge>
                </div>

                {/* Stats */}
                <div className="grid min-h-24 grid-cols-3 divide-x border-y px-0">
                  <div className="px-4 py-3">
                    <p className="min-h-8 text-xs leading-4 text-muted-foreground">Omzet Hari Ini</p>
                    <p className="font-bold text-sm mt-0.5"><CurrencyDisplay value={omzet} /></p>
                  </div>
                  <div className="px-4 py-3">
                    <p className="min-h-8 text-xs leading-4 text-muted-foreground">Transaksi</p>
                    <p className="font-bold text-sm mt-0.5">{transaksi}</p>
                  </div>
                  <div className="px-4 py-3">
                    <p className="min-h-8 text-xs leading-4 text-muted-foreground">Akun</p>
                    <p className="font-bold text-sm mt-0.5">{outletAccounts.length}</p>
                  </div>
                </div>

                {/* Actions */}
                <div className="mt-auto flex min-h-14 items-center justify-between px-3 py-2">
                  <Button
                    type="button"
                    variant="link"
                    size="sm"
                    className="h-auto p-0 text-xs"
                    onClick={() => setSelected(outlet)}
                  >
                    Lihat Detail
                  </Button>
                  <div className="flex items-center gap-1">
                  <Button
                    type="button"
                    variant="ghost"
                    size="icon-sm"
                    onClick={() => handleToggleActive(outlet)}
                    disabled={updateOutlet.isPending}
                    aria-label={`${outlet.is_active ? 'Nonaktifkan' : 'Aktifkan'} outlet ${outlet.name}`}
                    aria-pressed={outlet.is_active}
                    className="text-muted-foreground hover:text-foreground"
                  >
                    {outlet.is_active
                      ? <ToggleRight className="h-4 w-4 text-primary" />
                      : <ToggleLeft className="h-4 w-4" />}
                  </Button>
                  <Button
                    type="button"
                    variant="ghost"
                    size="icon-sm"
                    onClick={() => handleEdit(outlet)}
                    aria-label={`Edit outlet ${outlet.name}`}
                    className="text-muted-foreground hover:text-foreground"
                  >
                    <Pencil className="h-4 w-4" />
                  </Button>
                  <Button
                    type="button"
                    variant="ghost"
                    size="icon-sm"
                    onClick={() => setDeleteTarget(outlet)}
                    aria-label={`Hapus outlet ${outlet.name}`}
                    className="text-muted-foreground hover:bg-red-50 hover:text-destructive"
                  >
                    <Trash2 className="h-4 w-4" />
                  </Button>
                  </div>
                </div>
              </div>
            )
          })}
        </div>
      )}

      {/* Outlet Form Dialog */}
      <OutletFormDialog
        open={formOpen}
        onClose={() => { setFormOpen(false); setEditData(null) }}
        editData={editData}
      />

      {/* Detail Sheet */}
      <Sheet open={!!selected} onOpenChange={(o) => !o && setSelected(null)}>
        <SheetContent>
          <SheetHeader>
            <SheetTitle>{selected?.name}</SheetTitle>
          </SheetHeader>
          {selected && <OutletDetail outlet={selected} accounts={getOutletAccounts(selected.id)} />}
        </SheetContent>
      </Sheet>

      {/* Delete Confirmation */}
      <AlertDialog open={!!deleteTarget} onOpenChange={(o) => { if (!o && !deleting) { setDeleteTarget(null); setConfirmText('') } }}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>Hapus Outlet?</AlertDialogTitle>
            <AlertDialogDescription asChild>
              <div className="space-y-2">
                <p>
                  Outlet <strong>{deleteTarget?.name}</strong> akan dihapus permanen
                  beserta <strong>seluruh data terkait</strong>.
                </p>
                <p className="text-destructive text-sm font-medium">
                  ⚠️ Semua pesanan, shift, pembayaran, stok, voucher, pengeluaran, menu,
                  kategori, gambar, serta <strong>akun Kasir</strong> milik
                  cabang ini akan ikut terhapus permanen dan tidak bisa dikembalikan.
                </p>
                <p className="text-sm text-muted-foreground">
                  Ketik nama outlet <strong>{deleteTarget?.name}</strong> untuk konfirmasi:
                </p>
                <Input
                  value={confirmText}
                  onChange={(e) => setConfirmText(e.target.value)}
                  placeholder={deleteTarget?.name}
                  disabled={deleting}
                  autoFocus
                />
              </div>
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel disabled={deleting}>Batal</AlertDialogCancel>
            <AlertDialogAction
              onClick={(event) => {
                event.preventDefault()
                void handleDelete()
              }}
              disabled={deleting || confirmText.trim() !== deleteTarget?.name}
              className="bg-destructive text-destructive-foreground hover:bg-destructive/90"
            >
              {deleting ? 'Menghapus...' : 'Hapus permanen'}
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </div>
  )
}

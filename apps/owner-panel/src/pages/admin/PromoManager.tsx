import { useState, useMemo } from 'react'
import { useForm, useWatch } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import { z } from 'zod'
import { Plus, Pencil, ToggleLeft, ToggleRight, Trash2, Ticket, Copy } from 'lucide-react'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import { useOutlet } from '@/hooks/useOutlet'
import { useVouchers, useGenerateVouchers, useToggleVoucher } from '@/hooks/queries/useVouchers'
import { PageHeader } from '@/components/ui/PageHeader'
import { NoOutlet } from '@/components/ui/NoOutlet'
import { DataTable } from '@/components/ui/DataTable'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import { Dialog, DialogContent, DialogHeader, DialogTitle } from '@/components/ui/dialog'
import { Form, FormControl, FormField, FormItem, FormLabel, FormMessage } from '@/components/ui/form'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select'
import { Input } from '@/components/ui/input'
import { Textarea } from '@/components/ui/textarea'
import { useToast } from '@/hooks/use-toast'
import { humanizeError } from '@/lib/errorMessage'
import { cn } from '@/lib/utils'
import { CurrencyDisplay } from '@/components/ui/CurrencyDisplay'
import { ConfirmDialog } from '@/components/ui/ConfirmDialog'
import { format } from 'date-fns'
import type { Promo, PromoType } from '@/types/database'

const PROMO_LABELS: Record<PromoType, string> = {
  percentage: 'Persentase (%)', fixed: 'Potongan Tetap (Rp)', bundling: 'Bundling', bogo: 'Beli 1 Gratis 1',
}

const promoSchema = z.object({
  name: z.string().min(2, 'Nama minimal 2 karakter'),
  description: z.string().optional(),
  type: z.enum(['percentage', 'fixed', 'bundling', 'bogo']),
  value: z.string()
    .min(1, 'Nilai wajib diisi')
    .refine((value) => Number.isFinite(Number(value)) && Number(value) > 0, 'Nilai harus lebih dari 0'),
  min_order: z.string().refine(
    (value) => !value || (Number.isFinite(Number(value)) && Number(value) >= 0),
    'Minimum order minimal 0',
  ).optional(),
  max_discount: z.string().refine(
    (value) => !value || (Number.isFinite(Number(value)) && Number(value) > 0),
    'Maksimum diskon harus lebih dari 0',
  ).optional(),
  start_date: z.string().optional(),
  end_date: z.string().optional(),
  usage_limit: z.string().refine(
    (value) => !value || (Number.isInteger(Number(value)) && Number(value) >= 1),
    'Batas penggunaan harus bilangan bulat minimal 1',
  ).optional(),
}).refine(
  (d) => {
    if (!d.start_date || !d.end_date) return true
    return d.end_date >= d.start_date
  },
  { message: 'Tanggal berakhir harus setelah tanggal mulai', path: ['end_date'] }
)
type PromoValues = z.infer<typeof promoSchema>

function usePromos(outletId: string) {
  return useQuery({
    queryKey: ['promos', outletId],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('promos').select('*').eq('outlet_id', outletId).order('created_at', { ascending: false })
      if (error) throw error
      return data as Promo[]
    },
    enabled: !!outletId,
  })
}

export default function PromoManager() {
  const { activeOutletId } = useOutlet()
  const { data: promos = [], isLoading } = usePromos(activeOutletId ?? '')
  const today = useMemo(() => new Date().toISOString().slice(0, 10), [])
  const [dialogOpen, setDialogOpen] = useState(false)
  const [editPromo, setEditPromo] = useState<Promo | undefined>()
  const [voucherPromo, setVoucherPromo] = useState<Promo | null>(null)
  const [filter, setFilter] = useState<'all' | 'active' | 'scheduled' | 'ended'>('all')
  const qc = useQueryClient()
  const { toast } = useToast()

  const toggleMutation = useMutation({
    mutationFn: async ({ id, is_active }: { id: string; is_active: boolean }) => {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const { error } = await (supabase.from('promos') as any).update({ is_active }).eq('id', id)
      if (error) throw error
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: ['promos', activeOutletId] }),
    onError: (error: unknown) => toast({
      title: 'Gagal mengubah status promo',
      description: humanizeError(error),
      variant: 'destructive',
    }),
  })

  const deleteMutation = useMutation({
    mutationFn: async (id: string) => {
      // Hapus promo (voucher anaknya ikut terhapus via FK CASCADE).
      // Order/transaksi yg pernah memakai TIDAK terpengaruh (tidak ada FK ke promo).
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const { error } = await (supabase.from('promos') as any).delete().eq('id', id)
      if (error) throw error
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['promos', activeOutletId] })
      toast({ title: 'Promo dihapus' })
    },
    onError: (e: unknown) => toast({
      title: 'Gagal menghapus promo',
      description: humanizeError(e),
      variant: 'destructive',
    }),
  })

  const form = useForm<PromoValues>({
    resolver: zodResolver(promoSchema),
    defaultValues: { name: '', description: '', type: 'percentage', value: '', min_order: '', max_discount: '', start_date: '', end_date: '', usage_limit: '' },
  })
  const promoType = useWatch({ control: form.control, name: 'type' })
  const isPercentPromo = promoType === 'percentage'
  const filteredPromos = promos.filter((promo) => {
    const ended = Boolean(promo.end_date && promo.end_date.slice(0, 10) < today)
    const scheduled = Boolean(promo.start_date && promo.start_date.slice(0, 10) > today)
    if (filter === 'ended') return ended
    if (filter === 'scheduled') return scheduled
    if (filter === 'active') return promo.is_active && !ended && !scheduled
    return true
  })

  function openEdit(promo: Promo) {
    setEditPromo(promo)
    form.reset({
      name: promo.name, description: promo.description ?? '', type: promo.type,
      value: String(promo.value), min_order: String(promo.min_order),
      max_discount: promo.max_discount ? String(promo.max_discount) : '',
      start_date: promo.start_date?.slice(0, 10) ?? '', end_date: promo.end_date?.slice(0, 10) ?? '',
      usage_limit: promo.usage_limit ? String(promo.usage_limit) : '',
    })
    setDialogOpen(true)
  }

  async function onSubmit(values: PromoValues) {
    if (!activeOutletId) return
    const editing = dialogOpen ? editPromo : undefined
    const numValue = parseFloat(values.value)
    if (values.type === 'percentage' && numValue > 100) {
      form.setError('value', { message: 'Nilai persentase tidak boleh melebihi 100%' })
      return
    }
    const payload = {
      outlet_id: activeOutletId, name: values.name, description: values.description || null,
      type: values.type, value: numValue,
      min_order: values.min_order ? parseFloat(values.min_order) : 0,
      max_discount: values.max_discount ? parseFloat(values.max_discount) : null,
      start_date: values.start_date || null, end_date: values.end_date || null,
      usage_limit: values.usage_limit ? parseInt(values.usage_limit) : null,
      is_active: editing ? editing.is_active : true,
    }
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const tbl = supabase.from('promos') as any
    const { error } = editing ? await tbl.update(payload).eq('id', editing.id) : await tbl.insert(payload)
    if (error) { toast({ title: 'Gagal', description: humanizeError(error), variant: 'destructive' }); return }
    toast({ title: editing ? 'Promo diperbarui' : 'Promo ditambahkan' })
    qc.invalidateQueries({ queryKey: ['promos', activeOutletId] })
    setDialogOpen(false)
    if (!editing) form.reset()
  }

  if (!activeOutletId) return <NoOutlet />

  return (
    <div className="space-y-4">
      <PageHeader title="Promosi" subtitle="Harga khusus, diskon persentase, atau paket dengan periode berlaku yang jelas." />
      <div className="flex gap-2 overflow-x-auto">{([['all','Semua'],['active','Aktif'],['scheduled','Terjadwal'],['ended','Berakhir']] as const).map(([value, label]) => <button key={value} type="button" onClick={() => setFilter(value)} className={cn('min-h-11 rounded-full border px-5 text-sm font-semibold', filter === value ? 'border-[#C62828] bg-[#C62828] text-white' : 'bg-white text-[#374151]')}>{label}</button>)}</div>
      <div className="grid items-start gap-4 xl:grid-cols-[minmax(0,1fr)_360px]">
      <DataTable
        data={filteredPromos}
        loading={isLoading}
        getRowKey={(r) => r.id}
        emptyMessage="Belum ada promo."
        columns={[
          { key: 'name', header: 'Nama Promo', cell: (r) => <span className="font-medium">{r.name}</span> },
          { key: 'type', header: 'Tipe', cell: (r) => PROMO_LABELS[r.type] },
          { key: 'value', header: 'Nilai', cell: (r) => r.type === 'percentage' ? `${r.value}%` : <CurrencyDisplay value={r.value} /> },
          { key: 'min', header: 'Min Order', cell: (r) => r.min_order > 0 ? <CurrencyDisplay value={r.min_order} /> : '—' },
          { key: 'period', header: 'Periode', cell: (r) => r.start_date && r.end_date ? `${format(new Date(r.start_date),'d MMM')} – ${format(new Date(r.end_date),'d MMM yyyy')}` : 'Selamanya' },
          { key: 'usage', header: 'Pemakaian', cell: (r) => `${r.usage_count}${r.usage_limit ? ` / ${r.usage_limit}` : ''}` },
          { key: 'status', header: 'Status', cell: (r) => {
            const isExpired = !!r.end_date && r.end_date.slice(0, 10) < today
            if (isExpired) return <Badge variant="destructive">Kedaluwarsa</Badge>
            return <Badge variant={r.is_active ? 'default' : 'secondary'}>{r.is_active ? 'Aktif' : 'Nonaktif'}</Badge>
          } },
          { key: 'actions', header: '', cell: (r) => (
            <div className="flex gap-2 justify-end">
              <Button
                variant="ghost"
                size="icon-sm"
                aria-label={`Kelola kode voucher promo ${r.name}`}
                onClick={() => setVoucherPromo(r)}
              >
                <Ticket className="h-4 w-4" />
              </Button>
              <Button variant="ghost" size="icon-sm" onClick={() => openEdit(r)} aria-label={`Edit promo ${r.name}`}><Pencil className="h-4 w-4" /></Button>
              <Button
                variant="ghost"
                size="icon-sm"
                disabled={toggleMutation.isPending}
                onClick={() => toggleMutation.mutate({ id: r.id, is_active: !r.is_active })}
                aria-label={`${r.is_active ? 'Nonaktifkan' : 'Aktifkan'} promo ${r.name}`}
                aria-pressed={r.is_active}
              >
                {r.is_active ? <ToggleRight className="h-4 w-4 text-green-600" /> : <ToggleLeft className="h-4 w-4 text-muted-foreground" />}
              </Button>
              <ConfirmDialog
                title={`Hapus promo "${r.name}"?`}
                description="Promo (beserta voucher-nya) akan dihapus permanen. Transaksi/order yang pernah memakainya tidak terpengaruh."
                confirmLabel="Hapus"
                destructive
                onConfirm={() => deleteMutation.mutateAsync(r.id)}
                trigger={
                  <Button variant="ghost" size="icon-sm" className="text-destructive hover:text-destructive" aria-label={`Hapus promo ${r.name}`}>
                    <Trash2 className="h-4 w-4" />
                  </Button>
                }
              />
            </div>
          ), className: 'text-right' },
        ]}
      />
      <aside className="admin-card p-6"><h2 className="text-lg font-bold">Buat promo</h2><form className="mt-5 space-y-4" onSubmit={form.handleSubmit(onSubmit)}><label className="block"><span className="mb-1.5 block text-sm font-medium">Nama promo</span><Input placeholder="Contoh: Paket Hemat Siang" {...form.register('name')} />{form.formState.errors.name && <span className="text-xs text-red-600">{form.formState.errors.name.message}</span>}</label><div className="grid grid-cols-2 gap-3"><label><span className="mb-1.5 block text-sm font-medium">Jenis</span><select className="min-h-11 w-full rounded-xl border bg-white px-3 text-sm" {...form.register('type')}><option value="percentage">Diskon persentase</option><option value="fixed">Harga khusus</option><option value="bundling">Paket</option></select></label><label><span className="mb-1.5 block text-sm font-medium">Nilai</span><Input inputMode="numeric" placeholder="10" {...form.register('value')} /></label></div><div className="grid grid-cols-2 gap-3"><label><span className="mb-1.5 block text-sm font-medium">Mulai</span><Input type="date" {...form.register('start_date')} /></label><label><span className="mb-1.5 block text-sm font-medium">Selesai</span><Input type="date" {...form.register('end_date')} />{form.formState.errors.end_date && <span className="text-xs text-red-600">{form.formState.errors.end_date.message}</span>}</label></div><label className="block"><span className="mb-1.5 block text-sm font-medium">Produk yang ikut</span><Input disabled placeholder="Berlaku sesuai aturan promo outlet" /></label><Button type="submit" className="w-full"><Plus className="mr-2 h-4 w-4" />Simpan promo</Button></form></aside>
      </div>

      <Dialog open={dialogOpen} onOpenChange={(open) => { setDialogOpen(open); if (!open) { setEditPromo(undefined); form.reset() } }}>
        <DialogContent className="max-w-lg">
          <DialogHeader><DialogTitle>{editPromo ? 'Edit Promo' : 'Tambah Promo Baru'}</DialogTitle></DialogHeader>
          <Form {...form}>
            <form onSubmit={form.handleSubmit(onSubmit)} className="space-y-4">
              <FormField control={form.control} name="name" render={({ field }) => (
                <FormItem><FormLabel>Nama Promo</FormLabel><FormControl><Input placeholder="Diskon Akhir Pekan" {...field} /></FormControl><FormMessage /></FormItem>
              )} />
              <FormField control={form.control} name="description" render={({ field }) => (
                <FormItem><FormLabel>Deskripsi</FormLabel><FormControl><Textarea rows={2} {...field} /></FormControl><FormMessage /></FormItem>
              )} />
              <div className="grid grid-cols-2 gap-3">
                <FormField control={form.control} name="type" render={({ field }) => (
                  <FormItem><FormLabel>Tipe</FormLabel>
                    <Select onValueChange={field.onChange} value={field.value}>
                      <FormControl><SelectTrigger><SelectValue /></SelectTrigger></FormControl>
                      <SelectContent>{Object.entries(PROMO_LABELS).filter(([k]) => k !== 'bundling' && k !== 'bogo').map(([k, v]) => <SelectItem key={k} value={k}>{v}</SelectItem>)}</SelectContent>
                    </Select><FormMessage />
                  </FormItem>
                )} />
                <FormField control={form.control} name="value" render={({ field }) => (
                    <FormItem>
                      <FormLabel>Nilai {isPercentPromo ? '(%)' : '(Rp)'}</FormLabel>
                      <FormControl>
                        <Input
                          inputMode="numeric"
                          placeholder={isPercentPromo ? '10' : '10.000'}
                          value={!isPercentPromo && field.value
                            ? Number(field.value.toString().replace(/\./g, '')).toLocaleString('id-ID')
                            : field.value}
                          onChange={(e) => {
                            if (isPercentPromo) {
                              field.onChange(e.target.value.replace(/\D/g, ''))
                            } else {
                              field.onChange(e.target.value.replace(/\./g, '').replace(/\D/g, ''))
                            }
                          }}
                        />
                      </FormControl>
                      <FormMessage />
                    </FormItem>
                )} />
                <FormField control={form.control} name="min_order" render={({ field }) => (
                  <FormItem><FormLabel>Min Order (Rp)</FormLabel><FormControl>
                    <Input
                      inputMode="numeric"
                      placeholder="0"
                      value={field.value ? Number(field.value.toString().replace(/\./g, '')).toLocaleString('id-ID') : ''}
                      onChange={(e) => field.onChange(e.target.value.replace(/\./g, '').replace(/\D/g, ''))}
                    />
                  </FormControl><FormMessage /></FormItem>
                )} />
                <FormField control={form.control} name="max_discount" render={({ field }) => (
                  <FormItem><FormLabel>Maks Diskon (Rp)</FormLabel><FormControl>
                    <Input
                      inputMode="numeric"
                      placeholder="Opsional"
                      value={field.value ? Number(field.value.toString().replace(/\./g, '')).toLocaleString('id-ID') : ''}
                      onChange={(e) => field.onChange(e.target.value.replace(/\./g, '').replace(/\D/g, ''))}
                    />
                  </FormControl><FormMessage /></FormItem>
                )} />
                <FormField control={form.control} name="start_date" render={({ field }) => (
                  <FormItem><FormLabel>Tanggal Mulai</FormLabel><FormControl><Input type="date" {...field} /></FormControl><FormMessage /></FormItem>
                )} />
                <FormField control={form.control} name="end_date" render={({ field }) => (
                  <FormItem><FormLabel>Tanggal Berakhir</FormLabel><FormControl><Input type="date" {...field} /></FormControl><FormMessage /></FormItem>
                )} />
              </div>
              <FormField control={form.control} name="usage_limit" render={({ field }) => (
                <FormItem><FormLabel>Batas Pemakaian (opsional)</FormLabel><FormControl><Input type="number" min={1} placeholder="Tak terbatas" {...field} /></FormControl><FormMessage /></FormItem>
              )} />
              <div className="flex justify-end gap-2">
                <Button type="button" variant="outline" onClick={() => setDialogOpen(false)}>Batal</Button>
                <Button type="submit" disabled={form.formState.isSubmitting}>{form.formState.isSubmitting ? 'Menyimpan...' : 'Simpan'}</Button>
              </div>
            </form>
          </Form>
        </DialogContent>
      </Dialog>

      {voucherPromo && (
        <VoucherDialog
          promo={voucherPromo}
          outletId={activeOutletId ?? ''}
          onClose={() => setVoucherPromo(null)}
        />
      )}
    </div>
  )
}

// ── Kelola kode voucher untuk sebuah promo ────────────────────────────────────
function VoucherDialog({ promo, outletId, onClose }: { promo: Promo; outletId: string; onClose: () => void }) {
  const { toast } = useToast()
  const { data: vouchers = [], isLoading } = useVouchers(outletId, promo.id)
  const generate = useGenerateVouchers(outletId)
  const toggle = useToggleVoucher(outletId)
  const [count, setCount] = useState('5')
  const [usageLimit, setUsageLimit] = useState('1')

  function onGenerate() {
    const n = parseInt(count, 10)
    if (isNaN(n) || n < 1 || n > 100) {
      toast({ title: 'Jumlah kode harus 1–100', variant: 'destructive' }); return
    }
    const lim = usageLimit.trim() === '' ? null : parseInt(usageLimit, 10)
    if (lim !== null && (!Number.isFinite(lim) || lim < 1)) {
      toast({ title: 'Batas pakai minimal 1', variant: 'destructive' }); return
    }
    generate.mutate({ promoId: promo.id, count: n, usageLimit: lim }, {
      onSuccess: (rows) => toast({ title: `${rows.length} kode voucher dibuat` }),
      onError: (e) => toast({ title: 'Gagal membuat voucher', description: humanizeError(e), variant: 'destructive' }),
    })
  }

  async function copyVoucher(code: string) {
    try {
      if (!navigator.clipboard) throw new Error('Clipboard API tidak tersedia')
      await navigator.clipboard.writeText(code)
      toast({ title: `Kode ${code} disalin` })
    } catch {
      toast({
        title: 'Kode tidak dapat disalin otomatis',
        description: 'Pilih dan salin kode secara manual.',
        variant: 'destructive',
      })
    }
  }

  return (
    <Dialog open onOpenChange={(o) => { if (!o) onClose() }}>
      <DialogContent className="max-w-lg">
        <DialogHeader><DialogTitle>Kode Voucher — {promo.name}</DialogTitle></DialogHeader>

        {/* Generate */}
        <div className="flex flex-wrap items-end gap-2 rounded-lg border p-3">
          <div className="space-y-1">
            <label className="text-xs text-muted-foreground">Jumlah kode</label>
            <Input className="w-24" type="number" min={1} max={100} value={count} onChange={(e) => setCount(e.target.value)} />
          </div>
          <div className="space-y-1">
            <label className="text-xs text-muted-foreground">Batas pakai / kode</label>
            <Input className="w-32" type="number" min={1} placeholder="kosong = ∞" value={usageLimit} onChange={(e) => setUsageLimit(e.target.value)} />
          </div>
          <Button onClick={onGenerate} disabled={generate.isPending}>
            <Plus className="mr-1 h-4 w-4" /> {generate.isPending ? 'Membuat...' : 'Generate'}
          </Button>
        </div>

        {/* Daftar kode */}
        <div className="max-h-72 overflow-y-auto rounded-lg border">
          {isLoading ? (
            <p className="p-4 text-sm text-muted-foreground">Memuat...</p>
          ) : vouchers.length === 0 ? (
            <p className="p-4 text-sm text-muted-foreground">Belum ada kode. Klik "Generate" untuk membuat.</p>
          ) : (
            <div className="overflow-x-auto"><table className="w-full text-sm min-w-[560px]">
              <thead className="border-b bg-muted/40 text-xs text-muted-foreground">
                <tr>
                  <th className="px-3 py-2 text-left">Kode</th>
                  <th className="px-3 py-2 text-left">Pemakaian</th>
                  <th className="px-3 py-2 text-right">Aksi</th>
                </tr>
              </thead>
              <tbody>
                {vouchers.map((v) => (
                  <tr key={v.id} className="border-b last:border-0">
                    <td className="px-3 py-2 font-mono font-medium">
                      {v.code}{!v.is_active && <Badge variant="secondary" className="ml-2">Nonaktif</Badge>}
                    </td>
                    <td className="px-3 py-2 text-muted-foreground">
                      {v.usage_count}{v.usage_limit ? ` / ${v.usage_limit}` : ''}
                    </td>
                    <td className="px-3 py-2 text-right">
                      <Button variant="ghost" size="icon-sm" aria-label={`Salin kode voucher ${v.code}`}
                        onClick={() => void copyVoucher(v.code)}>
                        <Copy className="h-4 w-4" />
                      </Button>
                      <Button
                        variant="ghost"
                        size="icon-sm"
                        disabled={toggle.isPending}
                        aria-label={`${v.is_active ? 'Nonaktifkan' : 'Aktifkan'} voucher ${v.code}`}
                        aria-pressed={v.is_active}
                        onClick={() => toggle.mutate(
                          { id: v.id, is_active: !v.is_active },
                          {
                            onError: (error) => toast({
                              title: 'Gagal mengubah status voucher',
                              description: humanizeError(error),
                              variant: 'destructive',
                            }),
                          },
                        )}
                      >
                        {v.is_active ? <ToggleRight className="h-4 w-4 text-green-600" /> : <ToggleLeft className="h-4 w-4 text-muted-foreground" />}
                      </Button>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table></div>
          )}
        </div>
        <p className="text-xs text-muted-foreground">Kode inilah yang dimasukkan pelanggan di kolom "Kode voucher" saat checkout.</p>
      </DialogContent>
    </Dialog>
  )
}

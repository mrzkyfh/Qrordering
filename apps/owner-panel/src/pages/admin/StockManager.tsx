import { useState } from 'react'
import { useForm, useWatch } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import { z } from 'zod'
import { Plus, PackageOpen, Pencil, Trash2, FlaskConical } from 'lucide-react'
import { useOutlet } from '@/hooks/useOutlet'
import {
  useIngredients, useLowStock, useStockTransactions, useStockAdjustment,
  useCreateIngredient, useUpdateIngredient, useDeleteIngredient,
} from '@/hooks/queries/useIngredients'
import { useSuppliers } from '@/hooks/queries/useSuppliers'
import { useAuth } from '@/hooks/useAuth'
import { PageHeader } from '@/components/ui/PageHeader'
import { NoOutlet } from '@/components/ui/NoOutlet'
import { StatusBadge } from '@/components/ui/StatusBadge'
import { DataTable } from '@/components/ui/DataTable'
import { Button } from '@/components/ui/button'
import { Dialog, DialogContent, DialogHeader, DialogTitle } from '@/components/ui/dialog'
import { AlertDialog, AlertDialogAction, AlertDialogCancel, AlertDialogContent, AlertDialogDescription, AlertDialogFooter, AlertDialogHeader, AlertDialogTitle } from '@/components/ui/alert-dialog'
import { Form, FormControl, FormField, FormItem, FormLabel, FormMessage } from '@/components/ui/form'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select'
import { Input } from '@/components/ui/input'
import { Textarea } from '@/components/ui/textarea'
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs'
import { useToast } from '@/hooks/use-toast'
import { humanizeError } from '@/lib/errorMessage'
import { CurrencyDisplay } from '@/components/ui/CurrencyDisplay'
import { format } from 'date-fns'
import { id } from 'date-fns/locale'
import type { Ingredient, StockTransactionType } from '@/types/database'

// ── Adjustment form ──────────────────────────────────────────────────────────

const adjSchema = z.object({
  ingredient_id: z.string().min(1, 'Pilih bahan'),
  type: z.enum(['purchase', 'adjustment', 'waste', 'return']),
  qty: z.string().refine((v) => {
    const value = Number(v)
    return Number.isFinite(value) && value > 0
  }, { message: 'Jumlah harus lebih dari 0' }),
  cost_per_unit: z.string().refine((v) => {
    if (!v) return true
    const value = Number(v.replace(/\./g, ''))
    return Number.isFinite(value) && value >= 0
  }, 'Harga per unit minimal 0').optional(),
  supplier_id: z.string().optional(),
  reason: z.string().optional(),
  notes: z.string().optional(),
})

const WASTE_REASONS = ['expired', 'rusak', 'tumpah', 'lain'] as const
const WASTE_REASON_LABELS: Record<string, string> = {
  expired: 'Kedaluwarsa', rusak: 'Rusak', tumpah: 'Tumpah/Jatuh', lain: 'Lainnya',
}
type AdjValues = z.infer<typeof adjSchema>

// ── Ingredient create/edit form ──────────────────────────────────────────────

const ingredientSchema = z.object({
  name: z.string().min(1, 'Nama wajib diisi'),
  unit: z.string().min(1, 'Satuan wajib diisi'),
  initial_qty: z.string().refine((v) => {
    if (!v) return true
    const value = Number(v)
    return Number.isFinite(value) && value >= 0
  }, 'Stok awal minimal 0').optional(),
  cost_per_unit: z.string()
    .min(1, 'Harga/unit wajib diisi')
    .refine((v) => {
      const value = Number(v.replace(/\./g, ''))
      return Number.isFinite(value) && value >= 0
    }, 'Harga per unit minimal 0'),
  min_stock_qty: z.string()
    .min(1, 'Min stok wajib diisi')
    .refine((v) => {
      const value = Number(v)
      return Number.isFinite(value) && value >= 0
    }, 'Min stok minimal 0'),
})
type IngredientValues = z.infer<typeof ingredientSchema>

// ── Helpers ──────────────────────────────────────────────────────────────────

const TX_LABELS: Record<StockTransactionType, string> = {
  purchase: 'Pembelian', usage: 'Pemakaian', adjustment: 'Penyesuaian', waste: 'Pemborosan', return: 'Return',
}

function fmtPrice(raw: string) {
  const n = raw.replace(/\D/g, '')
  return n ? Number(n).toLocaleString('id-ID') : ''
}

function StockBadge({ item }: { item: Ingredient }) {
  if (item.stock_qty <= 0) return <StatusBadge status="out_of_stock" />
  if (item.stock_qty <= item.min_stock_qty * 0.5) return <StatusBadge status="critical" />
  if (item.stock_qty <= item.min_stock_qty) return <StatusBadge status="low" />
  return <StatusBadge status="ok" />
}

// ── Main Component ───────────────────────────────────────────────────────────

export default function StockManager() {
  const { activeOutletId } = useOutlet()
  const { user } = useAuth()
  const { toast } = useToast()

  const [adjOpen, setAdjOpen] = useState(false)
  const [createOpen, setCreateOpen] = useState(false)
  const [editTarget, setEditTarget] = useState<Ingredient | null>(null)
  const [deleteTarget, setDeleteTarget] = useState<Ingredient | null>(null)

  const { data: ingredients = [], isLoading } = useIngredients(activeOutletId ?? '')
  const { data: suppliers = [] } = useSuppliers(activeOutletId ?? '')
  const { data: lowStock = [] } = useLowStock(activeOutletId ?? '')
  const { data: transactions = [], isLoading: loadingTx } = useStockTransactions(activeOutletId ?? '')

  const adjust = useStockAdjustment()
  const createIngredient = useCreateIngredient()
  const updateIngredient = useUpdateIngredient()
  const deleteIngredient = useDeleteIngredient()

  // Adjustment form
  const adjForm = useForm<AdjValues>({
    resolver: zodResolver(adjSchema),
    defaultValues: { ingredient_id: '', type: 'purchase', qty: '', cost_per_unit: '', supplier_id: '', reason: '', notes: '' },
  })
  const adjustmentType = useWatch({
    control: adjForm.control,
    name: 'type',
  })

  async function onAdjSubmit(values: AdjValues) {
    if (!activeOutletId) return
    adjust.mutate({
      outlet_id: activeOutletId,
      ingredient_id: values.ingredient_id,
      type: values.type as StockTransactionType,
      qty: parseFloat(values.qty),
      cost_per_unit: values.cost_per_unit ? parseFloat(values.cost_per_unit) : undefined,
      supplier_id: values.type === 'purchase' && values.supplier_id ? values.supplier_id : null,
      reason: values.type === 'waste' && values.reason ? values.reason : null,
      notes: values.notes || undefined,
      created_by: user?.id,
    }, {
      onSuccess: () => { toast({ title: 'Stok berhasil diperbarui' }); adjForm.reset(); setAdjOpen(false) },
      onError: (e) => toast({ title: 'Gagal', description: humanizeError(e), variant: 'destructive' }),
    })
  }

  // Create ingredient form
  const createForm = useForm<IngredientValues>({
    resolver: zodResolver(ingredientSchema),
    defaultValues: { name: '', unit: '', initial_qty: '', cost_per_unit: '', min_stock_qty: '' },
  })

  async function onCreateSubmit(values: IngredientValues) {
    if (!activeOutletId) return
    createIngredient.mutate({
      outlet_id: activeOutletId,
      name: values.name,
      unit: values.unit,
      initial_qty: values.initial_qty ? parseFloat(values.initial_qty) : 0,
      cost_per_unit: parseFloat(values.cost_per_unit.replace(/\./g, '')),
      min_stock_qty: parseFloat(values.min_stock_qty),
      created_by: user?.id,
    }, {
      onSuccess: () => { toast({ title: 'Bahan baku berhasil ditambahkan' }); createForm.reset(); setCreateOpen(false) },
      onError: (e) => toast({ title: 'Gagal', description: humanizeError(e), variant: 'destructive' }),
    })
  }

  // Edit ingredient form
  const editForm = useForm<IngredientValues>({
    resolver: zodResolver(ingredientSchema),
    defaultValues: { name: '', unit: '', cost_per_unit: '', min_stock_qty: '' },
  })

  function openEdit(item: Ingredient) {
    setEditTarget(item)
    editForm.reset({
      name: item.name,
      unit: item.unit,
      cost_per_unit: item.cost_per_unit.toLocaleString('id-ID'),
      min_stock_qty: String(item.min_stock_qty),
    })
  }

  async function onEditSubmit(values: IngredientValues) {
    if (!editTarget || !activeOutletId) return
    updateIngredient.mutate({
      id: editTarget.id,
      outlet_id: activeOutletId,
      name: values.name,
      unit: values.unit,
      cost_per_unit: parseFloat(values.cost_per_unit.replace(/\./g, '')),
      min_stock_qty: parseFloat(values.min_stock_qty),
    }, {
      onSuccess: () => { toast({ title: 'Bahan baku berhasil diperbarui' }); setEditTarget(null) },
      onError: (e) => toast({ title: 'Gagal', description: humanizeError(e), variant: 'destructive' }),
    })
  }

  async function confirmDelete() {
    if (!deleteTarget || !activeOutletId) return
    try {
      const res = await deleteIngredient.mutateAsync({
        id: deleteTarget.id,
        outlet_id: activeOutletId,
      })
      toast({
        title: res.status === 'archived' ? 'Bahan baku di-arsipkan' : 'Bahan baku dihapus permanen',
        description: res.reason,
      })
      setDeleteTarget(null)
    } catch (error) {
      toast({ title: 'Gagal', description: humanizeError(error), variant: 'destructive' })
    }
  }

  if (!activeOutletId) return <NoOutlet />

  return (
    <div className="space-y-4">
      <PageHeader title="Stok Bahan Baku" subtitle={`${lowStock.length} bahan hampir habis`}>
        <Button variant="outline" onClick={() => setCreateOpen(true)}><FlaskConical className="mr-2 h-4 w-4" /> Tambah Bahan Baru</Button>
        <Button onClick={() => setAdjOpen(true)}><Plus className="mr-2 h-4 w-4" /> Tambah/Sesuaikan Stok</Button>
      </PageHeader>

      <Tabs defaultValue="list">
        <TabsList>
          <TabsTrigger value="list">Daftar Bahan</TabsTrigger>
          <TabsTrigger value="history">Riwayat Transaksi</TabsTrigger>
        </TabsList>

        <TabsContent value="list" className="mt-4">
          <DataTable
            data={ingredients}
            loading={isLoading}
            getRowKey={(r) => r.id}
            emptyMessage="Tidak ada bahan baku."
            columns={[
              { key: 'name', header: 'Nama Bahan', cell: (r) => <span className="font-medium">{r.name}</span> },
              { key: 'unit', header: 'Satuan', cell: (r) => r.unit },
              { key: 'stock', header: 'Stok Saat Ini', cell: (r) => <span className="font-mono">{r.stock_qty}</span> },
              { key: 'min', header: 'Min Stok', cell: (r) => <span className="text-muted-foreground">{r.min_stock_qty}</span> },
              { key: 'cost', header: 'Harga/Unit', cell: (r) => <CurrencyDisplay value={r.cost_per_unit} /> },
              { key: 'status', header: 'Status', cell: (r) => <StockBadge item={r} /> },
              {
                key: 'actions', header: '', cell: (r) => (
                  <div className="flex items-center gap-1 justify-end">
                    <Button size="icon-xs" variant="ghost" onClick={() => openEdit(r)} aria-label={`Edit bahan ${r.name}`}>
                      <Pencil className="h-3.5 w-3.5" />
                    </Button>
                    <Button size="icon-xs" variant="ghost" className="text-destructive hover:text-destructive" onClick={() => setDeleteTarget(r)} aria-label={`Hapus bahan ${r.name}`}>
                      <Trash2 className="h-3.5 w-3.5" />
                    </Button>
                  </div>
                ),
              },
            ]}
          />
        </TabsContent>

        <TabsContent value="history" className="mt-4">
          <DataTable
            data={transactions}
            loading={loadingTx}
            getRowKey={(r) => r.id}
            emptyMessage="Belum ada transaksi stok."
            columns={[
              { key: 'date', header: 'Tanggal', cell: (r) => format(new Date(r.created_at), 'd MMM yyyy HH:mm', { locale: id }) },
              { key: 'ingredient', header: 'Bahan', cell: (r) => r.ingredients?.name ?? '—' },
              { key: 'type', header: 'Tipe', cell: (r) => TX_LABELS[r.type] ?? r.type },
              { key: 'before', header: 'Sebelum', cell: (r) => <span className="font-mono">{r.qty_before}</span> },
              { key: 'qty', header: 'Perubahan', cell: (r) => {
                // 'adjustment' kini dua-arah: arah ditentukan qty_after vs qty_before.
                const up = r.type === 'adjustment' ? r.qty_after >= r.qty_before : ['purchase', 'return'].includes(r.type)
                return <span className={`font-mono font-medium ${up ? 'text-green-600' : 'text-red-600'}`}>{up ? '+' : '-'}{r.qty}</span>
              } },
              { key: 'after', header: 'Sesudah', cell: (r) => <span className="font-mono font-medium">{r.qty_after}</span> },
              { key: 'notes', header: 'Catatan', cell: (r) => <span className="text-muted-foreground text-xs">{r.notes ?? '—'}</span> },
            ]}
          />
        </TabsContent>
      </Tabs>

      {/* ── Tambah/Sesuaikan Stok dialog ─────────────────────────────────────── */}
      <Dialog open={adjOpen} onOpenChange={setAdjOpen}>
        <DialogContent className="max-w-md">
          <DialogHeader><DialogTitle className="flex items-center gap-2"><PackageOpen className="h-5 w-5" /> Tambah / Sesuaikan Stok</DialogTitle></DialogHeader>
          <Form {...adjForm}>
            <form onSubmit={adjForm.handleSubmit(onAdjSubmit)} className="space-y-4">
              <FormField control={adjForm.control} name="ingredient_id" render={({ field }) => (
                <FormItem>
                  <FormLabel>Bahan Baku</FormLabel>
                  <Select onValueChange={field.onChange} value={field.value}>
                    <FormControl><SelectTrigger><SelectValue placeholder="Pilih bahan" /></SelectTrigger></FormControl>
                    <SelectContent>{ingredients.map((i) => <SelectItem key={i.id} value={i.id}>{i.name} ({i.unit})</SelectItem>)}</SelectContent>
                  </Select>
                  <FormMessage />
                </FormItem>
              )} />
              <FormField control={adjForm.control} name="type" render={({ field }) => (
                <FormItem>
                  <FormLabel>Tipe Transaksi</FormLabel>
                  <Select onValueChange={field.onChange} value={field.value}>
                    <FormControl><SelectTrigger><SelectValue /></SelectTrigger></FormControl>
                    <SelectContent>
                      <SelectItem value="purchase">Pembelian (masuk)</SelectItem>
                      <SelectItem value="adjustment">Penyesuaian (masuk)</SelectItem>
                      <SelectItem value="waste">Pemborosan (keluar)</SelectItem>
                      <SelectItem value="return">Return (masuk)</SelectItem>
                    </SelectContent>
                  </Select>
                  <FormMessage />
                </FormItem>
              )} />
              <div className="grid grid-cols-2 gap-3">
                <FormField control={adjForm.control} name="qty" render={({ field }) => (
                  <FormItem>
                    <FormLabel>Jumlah</FormLabel>
                    <FormControl><Input type="number" min={0} step="0.01" placeholder="0" onKeyDown={(e) => e.key === '-' && e.preventDefault()} {...field} /></FormControl>
                    <FormMessage />
                  </FormItem>
                )} />
                <FormField control={adjForm.control} name="cost_per_unit" render={({ field }) => (
                  <FormItem>
                    <FormLabel>Harga/Unit (opsional)</FormLabel>
                    <FormControl>
                      <Input
                        inputMode="numeric"
                        placeholder="0"
                        value={field.value ? fmtPrice(field.value) : ''}
                        onChange={(e) => field.onChange(e.target.value.replace(/\D/g, ''))}
                      />
                    </FormControl>
                    <FormMessage />
                  </FormItem>
                )} />
              </div>
              {adjustmentType === 'waste' && (
                <FormField control={adjForm.control} name="reason" render={({ field }) => (
                  <FormItem>
                    <FormLabel>Alasan Waste</FormLabel>
                    <Select onValueChange={field.onChange} value={field.value}>
                      <FormControl>
                        <SelectTrigger><SelectValue placeholder="Pilih alasan" /></SelectTrigger>
                      </FormControl>
                      <SelectContent>
                        {WASTE_REASONS.map((r) => (
                          <SelectItem key={r} value={r}>{WASTE_REASON_LABELS[r]}</SelectItem>
                        ))}
                      </SelectContent>
                    </Select>
                    <FormMessage />
                  </FormItem>
                )} />
              )}
              {adjustmentType === 'purchase' && suppliers.length > 0 && (
                <FormField control={adjForm.control} name="supplier_id" render={({ field }) => (
                  <FormItem>
                    <FormLabel>Supplier (opsional)</FormLabel>
                    <Select onValueChange={field.onChange} value={field.value}>
                      <FormControl>
                        <SelectTrigger><SelectValue placeholder="Pilih supplier" /></SelectTrigger>
                      </FormControl>
                      <SelectContent>
                        {suppliers.map((s) => (
                          <SelectItem key={s.id} value={s.id}>{s.name}</SelectItem>
                        ))}
                      </SelectContent>
                    </Select>
                    <FormMessage />
                  </FormItem>
                )} />
              )}
              <FormField control={adjForm.control} name="notes" render={({ field }) => (
                <FormItem>
                  <FormLabel>Catatan</FormLabel>
                  <FormControl><Textarea rows={2} placeholder="Catatan opsional..." {...field} /></FormControl>
                  <FormMessage />
                </FormItem>
              )} />
              <div className="flex justify-end gap-2">
                <Button type="button" variant="outline" onClick={() => setAdjOpen(false)}>Batal</Button>
                <Button type="submit" disabled={adjust.isPending}>{adjust.isPending ? 'Menyimpan...' : 'Simpan'}</Button>
              </div>
            </form>
          </Form>
        </DialogContent>
      </Dialog>

      {/* ── Tambah Bahan Baru dialog ─────────────────────────────────────────── */}
      <Dialog open={createOpen} onOpenChange={setCreateOpen}>
        <DialogContent className="max-w-md">
          <DialogHeader><DialogTitle className="flex items-center gap-2"><FlaskConical className="h-5 w-5" /> Tambah Bahan Baru</DialogTitle></DialogHeader>
          <Form {...createForm}>
            <form onSubmit={createForm.handleSubmit(onCreateSubmit)} className="space-y-4">
              <div className="grid grid-cols-2 gap-3">
                <FormField control={createForm.control} name="name" render={({ field }) => (
                  <FormItem className="col-span-2">
                    <FormLabel>Nama Bahan</FormLabel>
                    <FormControl><Input placeholder="cth: Tepung Terigu" {...field} /></FormControl>
                    <FormMessage />
                  </FormItem>
                )} />
                <FormField control={createForm.control} name="unit" render={({ field }) => (
                  <FormItem>
                    <FormLabel>Satuan</FormLabel>
                    <FormControl><Input placeholder="cth: kg, liter, pcs" {...field} /></FormControl>
                    <FormMessage />
                  </FormItem>
                )} />
                <FormField control={createForm.control} name="initial_qty" render={({ field }) => (
                  <FormItem>
                    <FormLabel>Stok Awal</FormLabel>
                    <FormControl><Input type="number" min={0} step="0.01" placeholder="0" onKeyDown={(e) => e.key === '-' && e.preventDefault()} {...field} /></FormControl>
                    <FormMessage />
                  </FormItem>
                )} />
                <FormField control={createForm.control} name="cost_per_unit" render={({ field }) => (
                  <FormItem>
                    <FormLabel>Harga/Unit (Rp)</FormLabel>
                    <FormControl>
                      <Input
                        inputMode="numeric"
                        placeholder="0"
                        value={fmtPrice(field.value ?? '')}
                        onChange={(e) => field.onChange(e.target.value.replace(/\D/g, ''))}
                      />
                    </FormControl>
                    <FormMessage />
                  </FormItem>
                )} />
                <FormField control={createForm.control} name="min_stock_qty" render={({ field }) => (
                  <FormItem>
                    <FormLabel>Min Stok</FormLabel>
                    <FormControl><Input type="number" min={0} step="0.01" placeholder="0" onKeyDown={(e) => e.key === '-' && e.preventDefault()} {...field} /></FormControl>
                    <FormMessage />
                  </FormItem>
                )} />
              </div>
              <div className="flex justify-end gap-2">
                <Button type="button" variant="outline" onClick={() => setCreateOpen(false)}>Batal</Button>
                <Button type="submit" disabled={createIngredient.isPending}>{createIngredient.isPending ? 'Menyimpan...' : 'Tambah'}</Button>
              </div>
            </form>
          </Form>
        </DialogContent>
      </Dialog>

      {/* ── Edit Bahan dialog ────────────────────────────────────────────────── */}
      <Dialog open={!!editTarget} onOpenChange={(o) => { if (!o) setEditTarget(null) }}>
        <DialogContent className="max-w-md">
          <DialogHeader><DialogTitle className="flex items-center gap-2"><Pencil className="h-5 w-5" /> Edit Bahan</DialogTitle></DialogHeader>
          <Form {...editForm}>
            <form onSubmit={editForm.handleSubmit(onEditSubmit)} className="space-y-4">
              <div className="grid grid-cols-2 gap-3">
                <FormField control={editForm.control} name="name" render={({ field }) => (
                  <FormItem className="col-span-2">
                    <FormLabel>Nama Bahan</FormLabel>
                    <FormControl><Input {...field} /></FormControl>
                    <FormMessage />
                  </FormItem>
                )} />
                <FormField control={editForm.control} name="unit" render={({ field }) => (
                  <FormItem>
                    <FormLabel>Satuan</FormLabel>
                    <FormControl><Input {...field} /></FormControl>
                    <FormMessage />
                  </FormItem>
                )} />
                <FormField control={editForm.control} name="min_stock_qty" render={({ field }) => (
                  <FormItem>
                    <FormLabel>Min Stok</FormLabel>
                    <FormControl><Input type="number" min={0} step="0.01" onKeyDown={(e) => e.key === '-' && e.preventDefault()} {...field} /></FormControl>
                    <FormMessage />
                  </FormItem>
                )} />
                <FormField control={editForm.control} name="cost_per_unit" render={({ field }) => (
                  <FormItem className="col-span-2">
                    <FormLabel>Harga/Unit (Rp)</FormLabel>
                    <FormControl>
                      <Input
                        inputMode="numeric"
                        placeholder="0"
                        value={fmtPrice(field.value ?? '')}
                        onChange={(e) => field.onChange(e.target.value.replace(/\D/g, ''))}
                      />
                    </FormControl>
                    <FormMessage />
                  </FormItem>
                )} />
              </div>
              <div className="flex justify-end gap-2">
                <Button type="button" variant="outline" onClick={() => setEditTarget(null)}>Batal</Button>
                <Button type="submit" disabled={updateIngredient.isPending}>{updateIngredient.isPending ? 'Menyimpan...' : 'Simpan'}</Button>
              </div>
            </form>
          </Form>
        </DialogContent>
      </Dialog>

      {/* ── Konfirmasi hapus ─────────────────────────────────────────────────── */}
      <AlertDialog
        open={!!deleteTarget}
        onOpenChange={(open) => {
          if (!open && !deleteIngredient.isPending) setDeleteTarget(null)
        }}
      >
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>Hapus Bahan?</AlertDialogTitle>
            <AlertDialogDescription>
              Bahan <strong>{deleteTarget?.name}</strong> akan dinonaktifkan. Riwayat stok tetap tersimpan.
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel disabled={deleteIngredient.isPending}>Batal</AlertDialogCancel>
            <AlertDialogAction
              onClick={(event) => {
                event.preventDefault()
                void confirmDelete()
              }}
              disabled={deleteIngredient.isPending}
              className="bg-destructive text-destructive-foreground hover:bg-destructive/90"
            >
              {deleteIngredient.isPending ? 'Menghapus...' : 'Hapus'}
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </div>
  )
}

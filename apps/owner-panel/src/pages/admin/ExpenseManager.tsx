import { useState, useMemo } from 'react'
import { useForm } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import { z } from 'zod'
import { Plus, Pencil, Trash2 } from 'lucide-react'
import { format } from 'date-fns'
import { useAuth } from '@/hooks/useAuth'
import { useOutlet } from '@/hooks/useOutlet'
import { useExpenses, useCreateExpense, useUpdateExpense, useDeleteExpense } from '@/hooks/queries/useExpenses'
import { PageHeader } from '@/components/ui/PageHeader'
import { NoOutlet } from '@/components/ui/NoOutlet'
import { DataTable } from '@/components/ui/DataTable'
import { MonthPicker } from '@/components/ui/DateRangePicker'
import { CurrencyDisplay } from '@/components/ui/CurrencyDisplay'
import { ConfirmDialog } from '@/components/ui/ConfirmDialog'
import { Button } from '@/components/ui/button'
import { Dialog, DialogContent, DialogHeader, DialogTitle } from '@/components/ui/dialog'
import { Form, FormControl, FormField, FormItem, FormLabel, FormMessage } from '@/components/ui/form'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select'
import { Input } from '@/components/ui/input'
import { Textarea } from '@/components/ui/textarea'
import { useToast } from '@/hooks/use-toast'
import { humanizeError } from '@/lib/errorMessage'
import type { Expense, ExpenseCategory } from '@/types/database'

const CATEGORY_LABELS: Record<ExpenseCategory, string> = {
  bahan_baku: 'Bahan Baku',
  operasional: 'Operasional',
  gaji: 'Gaji',
  peralatan: 'Peralatan',
  marketing: 'Marketing',
  lain_lain: 'Lain-lain',
}

const expenseSchema = z.object({
  expense_date: z.string()
    .min(1, 'Tanggal wajib diisi')
    .refine((d) => d <= format(new Date(), 'yyyy-MM-dd'), { message: 'Tanggal tidak boleh di masa depan' }),
  category: z.enum(['bahan_baku', 'operasional', 'gaji', 'peralatan', 'marketing', 'lain_lain']),
  amount: z.string()
    .min(1, 'Nominal wajib diisi')
    .refine((value) => {
      const amount = Number(value.replace(/\./g, ''))
      return Number.isFinite(amount) && amount > 0
    }, 'Nominal harus lebih dari 0'),
  description: z.string().optional(),
})
type ExpenseValues = z.infer<typeof expenseSchema>

export default function ExpenseManager() {
  const { activeOutletId } = useOutlet()
  // Manajer boleh mencatat & menyunting pengeluaran di outletnya, tapi TIDAK
  // menghapus (RLS expenses_delete: owner/admin saja — lihat 128). Tombolnya
  // disembunyikan, bukan dibiarkan gagal: UPDATE/DELETE yang disaring RLS
  // membalas 204 No Content, bukan error, sehingga UI akan mengucap "terhapus"
  // padahal barisnya masih utuh.
  const canDelete = useAuth().hasRole(['owner', 'admin'])
  const [month, setMonth] = useState(format(new Date(), 'yyyy-MM'))
  const [dialogOpen, setDialogOpen] = useState(false)
  const [editExpense, setEditExpense] = useState<Expense | undefined>()
  const { toast } = useToast()

  const { data: expenses = [], isLoading } = useExpenses(activeOutletId, month)
  const createExpense = useCreateExpense(activeOutletId)
  const updateExpense = useUpdateExpense(activeOutletId)
  const deleteExpense = useDeleteExpense(activeOutletId)

  const categoryTotals = useMemo(() => {
    const totals: Partial<Record<ExpenseCategory, number>> = {}
    for (const e of expenses) {
      totals[e.category] = (totals[e.category] ?? 0) + e.amount
    }
    return totals
  }, [expenses])

  const grandTotal = expenses.reduce((s, e) => s + e.amount, 0)

  const form = useForm<ExpenseValues>({
    resolver: zodResolver(expenseSchema),
    defaultValues: {
      expense_date: format(new Date(), 'yyyy-MM-dd'),
      category: 'operasional',
      amount: '',
      description: '',
    },
  })

  function openAdd() {
    setEditExpense(undefined)
    form.reset({
      expense_date: format(new Date(), 'yyyy-MM-dd'),
      category: 'operasional',
      amount: '',
      description: '',
    })
    setDialogOpen(true)
  }

  function openEdit(expense: Expense) {
    setEditExpense(expense)
    form.reset({
      expense_date: expense.expense_date,
      category: expense.category,
      amount: String(expense.amount),
      description: expense.description ?? '',
    })
    setDialogOpen(true)
  }

  async function onSubmit(values: ExpenseValues) {
    const payload = {
      expense_date: values.expense_date,
      category: values.category,
      amount: parseFloat(values.amount.replace(/\./g, '')),
      description: values.description || null,
    }

    try {
      if (editExpense) {
        await updateExpense.mutateAsync({ id: editExpense.id, ...payload })
        toast({ title: 'Pengeluaran diperbarui' })
      } else {
        await createExpense.mutateAsync(payload)
        toast({ title: 'Pengeluaran ditambahkan' })
      }
      setDialogOpen(false)
    } catch (err) {
      toast({ title: 'Gagal', description: humanizeError(err), variant: 'destructive' })
    }
  }

  async function handleDelete(id: string) {
    try {
      await deleteExpense.mutateAsync(id)
      toast({ title: 'Pengeluaran dihapus' })
    } catch (err) {
      toast({ title: 'Gagal', description: humanizeError(err), variant: 'destructive' })
    }
  }

  if (!activeOutletId) return <NoOutlet />

  return (
    <div className="space-y-4">
      <PageHeader title="Pengeluaran" subtitle="Kelola pengeluaran operasional outlet">
        <MonthPicker value={month} onChange={setMonth} />
        <Button onClick={openAdd}>
          <Plus className="mr-2 h-4 w-4" /> Tambah
        </Button>
      </PageHeader>

      {/* Category summary cards */}
      <div className="grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-6">
        {(Object.keys(CATEGORY_LABELS) as ExpenseCategory[]).map((cat) => (
          <div
            key={cat}
            className="rounded-lg border border-gray-200 bg-white p-3 shadow-sm"
          >
            <p className="text-xs font-medium text-muted-foreground">{CATEGORY_LABELS[cat]}</p>
            <p className="mt-1 text-sm font-bold text-gray-900">
              <CurrencyDisplay value={categoryTotals[cat] ?? 0} />
            </p>
          </div>
        ))}
      </div>

      {/* Grand total */}
      <div className="flex items-center justify-end">
        <span className="text-sm text-muted-foreground mr-2">Total pengeluaran bulan ini:</span>
        <span className="font-bold text-lg">
          <CurrencyDisplay value={grandTotal} />
        </span>
      </div>

      <DataTable
        data={expenses}
        loading={isLoading}
        getRowKey={(r) => r.id}
        emptyMessage="Belum ada pengeluaran bulan ini."
        columns={[
          {
            key: 'date',
            header: 'Tanggal',
            cell: (r) => format(new Date(r.expense_date), 'd MMM yyyy'),
          },
          {
            key: 'category',
            header: 'Kategori',
            cell: (r) => (
              <span className="inline-flex rounded-full border border-gray-200 bg-gray-100 px-2 py-0.5 text-xs font-medium text-gray-700">
                {CATEGORY_LABELS[r.category]}
              </span>
            ),
          },
          {
            key: 'amount',
            header: 'Nominal',
            cell: (r) => <CurrencyDisplay value={r.amount} className="font-medium" />,
          },
          {
            key: 'description',
            header: 'Keterangan',
            cell: (r) => <span className="text-muted-foreground">{r.description || '—'}</span>,
          },
          {
            key: 'source',
            header: 'Sumber',
            cell: (r) => r.cash_movement_id ? (
              <span className="inline-flex rounded-full border border-blue-200 bg-blue-50 px-2 py-0.5 text-xs font-medium text-blue-700">
                Kas Keluar Otomatis
              </span>
            ) : (
              <span className="text-sm text-muted-foreground">Input Manual</span>
            ),
          },
          {
            key: 'actions',
            header: '',
            className: 'text-right',
            cell: (r) => (
              <div className="flex gap-1 justify-end">
                <Button variant="ghost" size="sm" onClick={() => openEdit(r)} aria-label="Edit pengeluaran">
                  <Pencil className="h-4 w-4" />
                </Button>
                {canDelete && !r.cash_movement_id && (
                  <ConfirmDialog
                    title="Hapus pengeluaran?"
                    description="Data pengeluaran ini akan dihapus permanen."
                    confirmLabel="Hapus"
                    destructive
                    onConfirm={() => handleDelete(r.id)}
                    trigger={
                      <Button variant="ghost" size="sm" className="text-destructive hover:text-destructive" aria-label="Hapus pengeluaran">
                        <Trash2 className="h-4 w-4" />
                      </Button>
                    }
                  />
                )}
              </div>
            ),
          },
        ]}
      />

      <Dialog open={dialogOpen} onOpenChange={setDialogOpen}>
        <DialogContent className="max-w-md">
          <DialogHeader>
            <DialogTitle>{editExpense ? 'Edit Pengeluaran' : 'Tambah Pengeluaran'}</DialogTitle>
          </DialogHeader>
          {editExpense?.cash_movement_id && (
            <div className="rounded-md border border-blue-200 bg-blue-50 px-3 py-2 text-sm text-blue-800">
              Pengeluaran ini dibuat otomatis dari Kas Keluar. Tanggal dan nominal mengikuti catatan kas.
            </div>
          )}
          <Form {...form}>
            <form onSubmit={form.handleSubmit(onSubmit)} className="space-y-4">
              <div className="grid grid-cols-2 gap-3">
                <FormField
                  control={form.control}
                  name="expense_date"
                  render={({ field }) => (
                    <FormItem>
                      <FormLabel>Tanggal</FormLabel>
                      <FormControl>
                        <Input type="date" disabled={!!editExpense?.cash_movement_id} {...field} />
                      </FormControl>
                      <FormMessage />
                    </FormItem>
                  )}
                />
                <FormField
                  control={form.control}
                  name="category"
                  render={({ field }) => (
                    <FormItem>
                      <FormLabel>Kategori</FormLabel>
                      <Select onValueChange={field.onChange} value={field.value}>
                        <FormControl>
                          <SelectTrigger>
                            <SelectValue />
                          </SelectTrigger>
                        </FormControl>
                        <SelectContent>
                          {(Object.entries(CATEGORY_LABELS) as [ExpenseCategory, string][]).map(
                            ([k, v]) => (
                              <SelectItem key={k} value={k}>
                                {v}
                              </SelectItem>
                            )
                          )}
                        </SelectContent>
                      </Select>
                      <FormMessage />
                    </FormItem>
                  )}
                />
              </div>
              <FormField
                control={form.control}
                name="amount"
                render={({ field }) => (
                  <FormItem>
                    <FormLabel>Nominal (Rp)</FormLabel>
                    <FormControl>
                      <Input
                        disabled={!!editExpense?.cash_movement_id}
                        inputMode="numeric"
                        placeholder="0"
                        value={
                          field.value
                            ? Number(
                                field.value.toString().replace(/\./g, '')
                              ).toLocaleString('id-ID')
                            : ''
                        }
                        onChange={(e) =>
                          field.onChange(e.target.value.replace(/\./g, '').replace(/\D/g, ''))
                        }
                      />
                    </FormControl>
                    <FormMessage />
                  </FormItem>
                )}
              />
              <FormField
                control={form.control}
                name="description"
                render={({ field }) => (
                  <FormItem>
                    <FormLabel>Keterangan <span className="text-muted-foreground text-xs">(opsional)</span></FormLabel>
                    <FormControl>
                      <Textarea rows={2} placeholder="Detail pengeluaran..." {...field} />
                    </FormControl>
                    <FormMessage />
                  </FormItem>
                )}
              />
              <div className="flex justify-end gap-2">
                <Button type="button" variant="outline" onClick={() => setDialogOpen(false)}>
                  Batal
                </Button>
                <Button type="submit" disabled={form.formState.isSubmitting}>
                  {form.formState.isSubmitting ? 'Menyimpan...' : 'Simpan'}
                </Button>
              </div>
            </form>
          </Form>
        </DialogContent>
      </Dialog>
    </div>
  )
}

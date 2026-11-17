import { useState, useEffect } from 'react'
import { useOutlet } from '@/hooks/useOutlet'
import { useUpdateOutlet } from '@/hooks/queries/useOutlets'
import { PageHeader } from '@/components/ui/PageHeader'
import { NoOutlet } from '@/components/ui/NoOutlet'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Separator } from '@/components/ui/separator'
import { cn } from '@/lib/utils'
import { useToast } from '@/hooks/use-toast'
import { humanizeError } from '@/lib/errorMessage'

const ROUNDING_OPTIONS = [
  { value: 0,    label: 'Tidak ada pembulatan' },
  { value: 100,  label: 'Ke Rp 100 terdekat' },
  { value: 500,  label: 'Ke Rp 500 terdekat' },
  { value: 1000, label: 'Ke Rp 1.000 terdekat' },
]

export default function ChargesSettings() {
  const { activeOutlet, activeOutletId } = useOutlet()
  const update = useUpdateOutlet()
  const { toast } = useToast()

  const [serviceCharge, setServiceCharge] = useState('0')
  const [rounding, setRounding] = useState(0)

  // Sinkronisasi pengaturan outlet (context) → state form lokal yang editable
  /* eslint-disable react-hooks/set-state-in-effect */
  useEffect(() => {
    if (!activeOutlet) return
    const s = activeOutlet.settings
    setServiceCharge(String(s?.service_charge_percent ?? 0))
    setRounding(s?.rounding ?? 0)
  }, [activeOutlet])
  /* eslint-enable react-hooks/set-state-in-effect */

  async function handleSave() {
    if (!activeOutletId || !activeOutlet) return
    const sc = serviceCharge.trim() === '' ? 0 : Number(serviceCharge)
    if (!Number.isFinite(sc) || sc < 0 || sc > 100) {
      toast({ title: 'Service charge harus antara 0 dan 100%', variant: 'destructive' })
      return
    }
    try {
      await update.mutateAsync({
        id: activeOutletId,
        updates: {
          settings: {
            ...activeOutlet.settings,
            service_charge_percent: sc,
            rounding,
          },
        },
      })
      toast({ title: 'Tersimpan', description: 'Pengaturan biaya berhasil diperbarui.' })
    } catch (error) {
      toast({
        title: 'Gagal menyimpan pengaturan biaya',
        description: humanizeError(error),
        variant: 'destructive',
      })
    }
  }

  if (!activeOutletId) return <NoOutlet />

  return (
    <div className="space-y-4">
      <PageHeader title="Biaya" subtitle="Pengaturan service charge dan pembulatan harga">
        <Button onClick={handleSave} disabled={update.isPending}>
          {update.isPending ? 'Menyimpan...' : 'Simpan'}
        </Button>
      </PageHeader>

      <div className="rounded-xl border bg-white shadow-sm p-5 max-w-lg space-y-6">
        {/* Service charge */}
        <div className="space-y-3">
          <div>
            <p className="font-medium text-sm">Service Charge</p>
            <p className="text-xs text-muted-foreground mt-0.5">
              Biaya layanan yang ditambahkan ke setiap transaksi
            </p>
          </div>
          <div className="flex items-center gap-2 max-w-[180px]">
            <Input
              type="number"
              min={0}
              max={100}
              step={0.1}
              value={serviceCharge}
              onChange={(e) => setServiceCharge(e.target.value)}
            />
            <span className="text-sm font-medium shrink-0">%</span>
          </div>
          {Number(serviceCharge) > 0 && (
            <p className="text-xs text-muted-foreground">
              Contoh: transaksi Rp 100.000 → service charge Rp {(100000 * Number(serviceCharge) / 100).toLocaleString('id-ID')}
            </p>
          )}
        </div>

        <Separator />

        {/* Rounding */}
        <div className="space-y-3">
          <div>
            <p className="font-medium text-sm">Pembulatan Total</p>
            <p className="text-xs text-muted-foreground mt-0.5">
              Membulatkan total tagihan untuk kemudahan pembayaran tunai
            </p>
          </div>
          <div className="space-y-2">
            {ROUNDING_OPTIONS.map((opt) => (
              <button
                key={opt.value}
                type="button"
                onClick={() => setRounding(opt.value)}
                aria-pressed={rounding === opt.value}
                className={cn(
                  'w-full flex items-center gap-3 rounded-lg border px-4 py-3 text-sm text-left transition-colors',
                  rounding === opt.value
                    ? 'border-primary bg-primary/5 text-primary font-medium'
                    : 'border-border hover:bg-muted/50'
                )}
              >
                <span className={cn(
                  'flex h-4 w-4 items-center justify-center rounded-full border-2 shrink-0',
                  rounding === opt.value ? 'border-primary' : 'border-muted-foreground/40'
                )}>
                  {rounding === opt.value && (
                    <span className="h-2 w-2 rounded-full bg-primary" />
                  )}
                </span>
                {opt.label}
              </button>
            ))}
          </div>
        </div>
      </div>

      <div className="rounded-lg bg-muted/50 border px-4 py-3 max-w-lg">
        <Label className="text-xs text-muted-foreground">Catatan</Label>
        <p className="text-xs text-muted-foreground mt-0.5">
          Service charge dan pembulatan berlaku untuk semua jenis transaksi di outlet ini.
          Perubahan hanya berlaku untuk transaksi baru.
        </p>
      </div>
    </div>
  )
}

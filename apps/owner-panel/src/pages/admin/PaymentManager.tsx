import { useState, useEffect } from 'react'
import { Banknote, QrCode, CreditCard, Wallet, Building2 } from 'lucide-react'
import { useOutlet } from '@/hooks/useOutlet'
import { useUpdateOutlet } from '@/hooks/queries/useOutlets'
import { PageHeader } from '@/components/ui/PageHeader'
import { NoOutlet } from '@/components/ui/NoOutlet'
import { Button } from '@/components/ui/button'
import { Switch } from '@/components/ui/switch'
import { useToast } from '@/hooks/use-toast'
import { humanizeError } from '@/lib/errorMessage'

const METHODS = [
  { key: 'cash',     label: 'Tunai',         desc: 'Pembayaran dengan uang tunai',              icon: Banknote },
  { key: 'qris',     label: 'QRIS',          desc: 'QR Code Indonesian Standard',               icon: QrCode },
  { key: 'debit',    label: 'Kartu Debit',   desc: 'Pembayaran menggunakan kartu debit/ATM',    icon: CreditCard },
  { key: 'credit',   label: 'Kartu Kredit',  desc: 'Pembayaran menggunakan kartu kredit',       icon: CreditCard },
  { key: 'ewallet',  label: 'E-Wallet',      desc: 'GoPay, OVO, Dana, ShopeePay, dll.',         icon: Wallet },
  { key: 'transfer', label: 'Transfer Bank', desc: 'Transfer antar rekening bank',              icon: Building2 },
]

export default function PaymentManager() {
  const { activeOutlet, activeOutletId } = useOutlet()
  const update = useUpdateOutlet()
  const { toast } = useToast()

  const defaultMethods = ['cash', 'qris']
  const [enabled, setEnabled] = useState<string[]>(defaultMethods)

  // Sinkronisasi pengaturan outlet (context) → state form lokal yang editable
  useEffect(() => {
    if (activeOutlet?.settings?.payment_methods) {
      // eslint-disable-next-line react-hooks/set-state-in-effect
      setEnabled(activeOutlet.settings.payment_methods)
    }
  }, [activeOutlet])

  function toggle(key: string) {
    setEnabled((prev) =>
      prev.includes(key) ? prev.filter((k) => k !== key) : [...prev, key]
    )
  }

  async function handleSave() {
    if (!activeOutletId || !activeOutlet) return
    if (enabled.length === 0) {
      toast({ title: 'Minimal 1 metode pembayaran harus aktif', variant: 'destructive' })
      return
    }
    try {
      await update.mutateAsync({
        id: activeOutletId,
        updates: {
          settings: { ...activeOutlet.settings, payment_methods: enabled },
        },
      })
      toast({ title: 'Tersimpan', description: 'Metode pembayaran berhasil diperbarui.' })
    } catch (error) {
      toast({
        title: 'Gagal menyimpan metode pembayaran',
        description: humanizeError(error),
        variant: 'destructive',
      })
    }
  }

  if (!activeOutletId) return <NoOutlet />

  return (
    <div className="space-y-4">
      <PageHeader title="Metode Pembayaran" subtitle="Aktifkan metode pembayaran yang tersedia di outlet ini">
        <Button onClick={handleSave} disabled={update.isPending}>
          {update.isPending ? 'Menyimpan...' : 'Simpan'}
        </Button>
      </PageHeader>

      <div className="space-y-2">
        {METHODS.map(({ key, label, desc, icon: Icon }) => (
          <div
            key={key}
            className="flex items-center justify-between rounded-xl border bg-white px-4 py-4 shadow-sm"
          >
            <div className="flex items-center gap-3">
              <div className="flex h-10 w-10 items-center justify-center rounded-full bg-muted shrink-0">
                <Icon className="h-5 w-5 text-muted-foreground" />
              </div>
              <div>
                <p className="font-medium text-sm">{label}</p>
                <p className="text-xs text-muted-foreground">{desc}</p>
              </div>
            </div>
            <Switch
              aria-label={`${enabled.includes(key) ? 'Nonaktifkan' : 'Aktifkan'} metode ${label}`}
              checked={enabled.includes(key)}
              onCheckedChange={() => toggle(key)}
            />
          </div>
        ))}
      </div>

      <p className="text-xs text-muted-foreground px-1">
        Minimal 1 metode pembayaran harus aktif. Metode yang dinonaktifkan tidak akan muncul di kasir.
      </p>
    </div>
  )
}

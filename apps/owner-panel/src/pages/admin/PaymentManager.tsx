import { useEffect, useState } from 'react'
import { format } from 'date-fns'
import { id } from 'date-fns/locale'
import { Clock3, Info, QrCode, ShieldCheck } from 'lucide-react'
import { useOutlet } from '@/hooks/useOutlet'
import { useUpdateOutlet } from '@/hooks/queries/useOutlets'
import { uploadImageAsset } from '@/lib/imageStorage'
import { PageHeader } from '@/components/ui/PageHeader'
import { NoOutlet } from '@/components/ui/NoOutlet'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Switch } from '@/components/ui/switch'
import { useToast } from '@/hooks/use-toast'
import { humanizeError } from '@/lib/errorMessage'
import { CurrencyDisplay } from '@/components/ui/CurrencyDisplay'
import { usePaymentClaims, useReviewPaymentClaim } from '@/hooks/queries/usePaymentClaims'

export default function PaymentManager() {
  const { activeOutlet, activeOutletId } = useOutlet()
  const update = useUpdateOutlet()
  const { toast } = useToast()
  const [merchant, setMerchant] = useState('')
  const [qrisUrl, setQrisUrl] = useState<string | null>(null)
  const [timeout, setTimeoutValue] = useState(15)
  const [afterPayment, setAfterPayment] = useState(true)
  const [allowProof, setAllowProof] = useState(true)
  const [uploading, setUploading] = useState(false)
  const { data: verificationHistory = [], isLoading: loadingHistory } = usePaymentClaims(activeOutletId ?? '')
  const reviewClaim = useReviewPaymentClaim(activeOutletId ?? '')

  async function review(id: string, decision: 'PAID' | 'VERIFICATION_FAILED') {
    const reason = decision === 'VERIFICATION_FAILED' ? window.prompt('Alasan penolakan pembayaran:')?.trim() : undefined
    if (decision === 'VERIFICATION_FAILED' && (!reason || reason.length < 3)) return
    try { await reviewClaim.mutateAsync({ id, decision, reason }); toast({ title: decision === 'PAID' ? 'Pembayaran dikonfirmasi' : 'Klaim ditolak' }) }
    catch (error) { toast({ title: 'Verifikasi gagal', description: humanizeError(error), variant: 'destructive' }) }
  }

  useEffect(() => {
    const settings = activeOutlet?.settings
    if (!settings) return
    // eslint-disable-next-line react-hooks/set-state-in-effect
    setMerchant(settings.qris_merchant_name ?? '')
    setQrisUrl(settings.qris_image_url ?? null)
    setTimeoutValue(settings.payment_timeout_minutes ?? 15)
    setAfterPayment(settings.kitchen_after_payment ?? true)
    setAllowProof(settings.allow_payment_proof ?? true)
  }, [activeOutlet])

  async function handleUpload(file?: File) {
    if (!file || !activeOutletId) return
    setUploading(true)
    try { setQrisUrl(await uploadImageAsset(file, activeOutletId, 'logos')) }
    catch (error) { toast({ title: 'Gagal mengunggah QRIS', description: humanizeError(error), variant: 'destructive' }) }
    finally { setUploading(false) }
  }

  async function handleSave() {
    if (!activeOutletId || !activeOutlet) return
    try {
      await update.mutateAsync({ id: activeOutletId, updates: { settings: {
        ...activeOutlet.settings, payment_methods: ['cash', 'qris'], qris_merchant_name: merchant.trim(),
        qris_image_url: qrisUrl, payment_timeout_minutes: Math.max(1, timeout),
        kitchen_after_payment: afterPayment, allow_payment_proof: allowProof,
      } } })
      toast({ title: 'Pengaturan pembayaran disimpan' })
    } catch (error) { toast({ title: 'Gagal menyimpan', description: humanizeError(error), variant: 'destructive' }) }
  }

  if (!activeOutletId) return <NoOutlet />
  return (
    <div className="space-y-6">
      <PageHeader title="Pembayaran" subtitle="Atur QRIS statis dan alur verifikasi pembayaran outlet.">
        <Button onClick={handleSave} disabled={update.isPending || uploading}>{update.isPending ? 'Menyimpan...' : 'Simpan perubahan'}</Button>
      </PageHeader>
      <div className="grid gap-5 xl:grid-cols-2">
        <section className="admin-card p-6" aria-labelledby="qris-heading">
          <div className="mb-5 flex items-center gap-3"><span className="rounded-xl bg-[#CCFBF1] p-2.5"><QrCode className="h-5 w-5 text-[#0F766E]" /></span><div><h2 id="qris-heading" className="font-semibold">QRIS restoran</h2><p className="text-sm text-muted-foreground">QR yang ditampilkan kepada pelanggan.</p></div></div>
          <div className="grid gap-5 sm:grid-cols-[180px_1fr]">
            <div className="flex aspect-square items-center justify-center overflow-hidden rounded-2xl border border-dashed bg-[#F7F7F8]">{qrisUrl ? <img src={qrisUrl} alt="QRIS restoran" className="h-full w-full object-contain p-3" /> : <QrCode className="h-16 w-16 text-gray-300" />}</div>
            <div className="space-y-4">
              <div><label htmlFor="merchant" className="mb-1.5 block text-sm font-medium">Nama merchant</label><Input id="merchant" value={merchant} onChange={(e) => setMerchant(e.target.value)} placeholder="Nama pada QRIS" /></div>
              <div><label htmlFor="qris-file" className="mb-1.5 block text-sm font-medium">Gambar QRIS</label><Input id="qris-file" type="file" accept="image/png,image/jpeg,image/webp" onChange={(e) => handleUpload(e.target.files?.[0])} /></div>
              <p className="flex gap-2 rounded-xl bg-blue-50 p-3 text-sm text-blue-900"><Info className="mt-0.5 h-4 w-4 shrink-0" />QRIS statis tidak dikonfirmasi otomatis dan wajib diverifikasi oleh Pelayan.</p>
            </div>
          </div>
        </section>
        <section className="admin-card p-6" aria-labelledby="rules-heading">
          <div className="mb-5 flex items-center gap-3"><span className="rounded-xl bg-[#CCFBF1] p-2.5"><Clock3 className="h-5 w-5 text-[#0F766E]" /></span><div><h2 id="rules-heading" className="font-semibold">Aturan pembayaran</h2><p className="text-sm text-muted-foreground">Berlaku untuk pesanan QR di outlet ini.</p></div></div>
          <div className="space-y-5">
            <div><label htmlFor="payment-timeout" className="mb-1.5 block text-sm font-medium">Batas waktu bayar (menit)</label><Input id="payment-timeout" type="number" min={1} max={120} value={timeout} onChange={(e) => setTimeoutValue(Number(e.target.value))} /></div>
            <div className="flex min-h-16 items-center justify-between gap-4 rounded-xl border p-4"><div><p className="text-sm font-medium">Masuk dapur setelah pembayaran dikonfirmasi</p><p className="text-xs text-muted-foreground">Pesanan belum lunas tidak diproses.</p></div><Switch checked={afterPayment} onCheckedChange={setAfterPayment} aria-label="Pesanan masuk dapur setelah pembayaran" /></div>
            <div className="flex min-h-16 items-center justify-between gap-4 rounded-xl border p-4"><div><p className="text-sm font-medium">Izinkan unggah bukti bayar</p><p className="text-xs text-muted-foreground">Pelanggan dapat mengirim bukti QRIS.</p></div><Switch checked={allowProof} onCheckedChange={setAllowProof} aria-label="Izinkan unggah bukti bayar" /></div>
          </div>
        </section>
      </div>
      <section className="admin-card overflow-hidden" aria-labelledby="history-heading">
        <div className="border-b p-5"><div className="flex items-center gap-2"><ShieldCheck className="h-5 w-5 text-[#0F766E]" /><h2 id="history-heading" className="font-semibold">Riwayat verifikasi</h2></div><p className="mt-1 text-sm text-muted-foreground">Audit konfirmasi dan penolakan pembayaran oleh petugas.</p></div>
        <div className="overflow-x-auto"><table className="w-full min-w-[860px] text-sm"><thead className="bg-gray-50 text-left text-xs uppercase text-muted-foreground"><tr><th className="px-5 py-3">Pesanan</th><th className="px-5 py-3">Petugas</th><th className="px-5 py-3">Waktu</th><th className="px-5 py-3">Nominal</th><th className="px-5 py-3">Keputusan</th><th className="px-5 py-3">Aksi</th></tr></thead><tbody>{loadingHistory ? <tr><td colSpan={6} className="px-5 py-10 text-center text-muted-foreground">Memuat riwayat...</td></tr> : verificationHistory.length === 0 ? <tr><td colSpan={6} className="px-5 py-10 text-center text-muted-foreground">Belum ada klaim pembayaran.</td></tr> : verificationHistory.map((row) => { const pending = row.status === 'PENDING' || row.status === 'WAITING_VERIFICATION'; return <tr key={row.id} className="border-t"><td className="px-5 py-4 font-semibold">{row.orders?.order_number ?? '—'}</td><td className="px-5 py-4">{row.profiles?.full_name ?? (pending ? 'Belum diperiksa' : 'Petugas')}</td><td className="px-5 py-4">{format(new Date(row.submitted_at ?? row.created_at), 'd MMM yyyy, HH:mm', { locale: id })}</td><td className="px-5 py-4 font-semibold"><CurrencyDisplay value={row.orders?.total_amount ?? 0} /></td><td className="px-5 py-4"><span className={pending ? 'rounded-full bg-amber-100 px-2.5 py-1 text-xs font-semibold text-amber-900' : row.status === 'PAID' ? 'rounded-full bg-green-100 px-2.5 py-1 text-xs font-semibold text-green-800' : 'rounded-full bg-gray-200 px-2.5 py-1 text-xs font-semibold text-gray-700'}>{pending ? 'Belum terverifikasi' : row.status === 'PAID' ? 'Dikonfirmasi' : row.status}</span>{row.rejection_reason && <span className="ml-2 text-xs text-muted-foreground">{row.rejection_reason}</span>}</td><td className="px-5 py-4">{pending ? <div className="flex gap-2"><Button size="sm" disabled={reviewClaim.isPending} onClick={() => void review(row.id, 'PAID')}>Konfirmasi</Button><Button size="sm" variant="outline" disabled={reviewClaim.isPending} onClick={() => void review(row.id, 'VERIFICATION_FAILED')}>Tolak</Button></div> : '—'}</td></tr> })}</tbody></table></div>
      </section>
    </div>
  )
}

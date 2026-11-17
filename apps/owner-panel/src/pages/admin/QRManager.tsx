import { useState } from 'react'
import QRCode from 'qrcode'
import { AlertCircle, QrCode, RefreshCw, Download } from 'lucide-react'
import { useOutlet } from '@/hooks/useOutlet'
import { useTables } from '@/hooks/queries/useOutlets'
import { useRealtimeTables } from '@/hooks/useRealtimeOrders'
import { supabase } from '@/lib/supabase'
import { PageHeader } from '@/components/ui/PageHeader'
import { NoOutlet } from '@/components/ui/NoOutlet'
import { Button } from '@/components/ui/button'
import { Dialog, DialogContent, DialogHeader, DialogTitle } from '@/components/ui/dialog'
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from '@/components/ui/alert-dialog'
import { Badge } from '@/components/ui/badge'
import { DataTable } from '@/components/ui/DataTable'
import { useToast } from '@/hooks/use-toast'
import { useQueryClient } from '@tanstack/react-query'
import { humanizeError } from '@/lib/errorMessage'
import type { RestaurantTable } from '@/types/database'
import logo from '@/assets/logo.png'

function resolveMenuBaseUrl(): string {
  const configured = (import.meta.env.VITE_MENU_BASE_URL as string | undefined)?.trim()
  if (configured) return configured

  // Workers dalam akun yang sama memakai suffix workers.dev yang sama. Dengan
  // ini QR tidak memerlukan custom domain atau hardcode subdomain akun.
  const hostname = window.location.hostname
  if (hostname.startsWith('qrordering.') && hostname.endsWith('.workers.dev')) {
    return `${window.location.protocol}//qrordering-menu.${hostname.slice('qrordering.'.length)}`
  }

  throw new Error('Alamat menu pelanggan belum dikonfigurasi.')
}

// Escape nilai dinamis agar tidak jadi DOM XSS saat ditulis ke window cetak.
function escapeHtml(s: string): string {
  return s.replace(/[&<>"']/g, (c) =>
    ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]!))
}

interface QRBranding {
  businessName: string
  outletName: string
  address: string
  phone: string
  logoUrl: string
}

function tableLabel(tableNumber: string): string {
  const value = tableNumber.trim()
  if (!value) return 'Meja tanpa nomor'
  return /^meja\b/i.test(value) ? value : `Meja ${value}`
}

function buildMenuUrl(token: string): string {
  const url = new URL(resolveMenuBaseUrl())
  const isLocal = url.hostname === 'localhost' || url.hostname === '127.0.0.1'
  if (!['http:', 'https:'].includes(url.protocol) || (import.meta.env.PROD && !isLocal && url.protocol !== 'https:')) {
    throw new Error('Alamat customer menu harus menggunakan HTTPS.')
  }
  url.searchParams.set('token', token)
  return url.toString()
}

function safeImageUrl(url: string): string {
  return /^(https?:\/\/|data:image\/|\/)/i.test(url) ? escapeHtml(url) : ''
}

function isQrPngDataUrl(value: string): boolean {
  return /^data:image\/png;base64,[a-z0-9+/=\s]+$/i.test(value)
}

function hasUsableQR(table: RestaurantTable): boolean {
  return Boolean(table.qr_token?.trim() && table.qr_code_url && isQrPngDataUrl(table.qr_code_url))
}

function hasAnyQRData(table: RestaurantTable): boolean {
  return Boolean(table.qr_token?.trim() || table.qr_code_url?.trim())
}

function formatGeneratedAt(value: string | null): string {
  if (!value) return '—'
  const date = new Date(value)
  return Number.isNaN(date.getTime()) ? 'Data tanggal tidak valid' : date.toLocaleDateString('id-ID')
}

function loadImage(src: string): Promise<HTMLImageElement> {
  return new Promise((resolve, reject) => {
    const image = new Image()
    if (/^https?:\/\//i.test(src)) image.crossOrigin = 'anonymous'
    image.onload = () => resolve(image)
    image.onerror = () => reject(new Error('Gambar tidak dapat dimuat'))
    image.src = src
  })
}

async function downloadQRPoster(dataUrl: string, table: RestaurantTable, branding: QRBranding) {
  if (!isQrPngDataUrl(dataUrl)) throw new Error('Data QR tidak valid. Buat ulang QR Code meja ini.')
  const canvas = document.createElement('canvas')
  // A5 portrait pada 300 DPI agar mudah dipasang tegak di meja/dinding.
  canvas.width = 1748
  canvas.height = 2480
  const ctx = canvas.getContext('2d')
  if (!ctx) throw new Error('Canvas tidak tersedia')

  const ivory = '#fbf8ef'
  const ink = '#30271c'
  const red = '#9f1d20'
  const darkRed = '#761317'
  const gold = '#c5a15a'

  ctx.fillStyle = ivory
  ctx.fillRect(0, 0, canvas.width, canvas.height)
  const glow = ctx.createRadialGradient(874, 1240, 80, 874, 1240, 1600)
  glow.addColorStop(0, 'rgba(255,255,255,.68)')
  glow.addColorStop(1, 'rgba(197,161,90,.07)')
  ctx.fillStyle = glow
  ctx.fillRect(0, 0, canvas.width, canvas.height)
  ctx.strokeStyle = 'rgba(197,161,90,.46)'
  ctx.lineWidth = 5
  ctx.strokeRect(35, 35, canvas.width - 70, canvas.height - 70)

  const logoImage = await loadImage(branding.logoUrl).catch(() => loadImage(logo))
  const logoSize = 250
  ctx.save()
  ctx.beginPath()
  ctx.arc(255, 245, logoSize / 2, 0, Math.PI * 2)
  ctx.clip()
  ctx.drawImage(logoImage, 130, 120, logoSize, logoSize)
  ctx.restore()

  ctx.textAlign = 'left'
  ctx.fillStyle = ink
  ctx.font = '700 94px Georgia, serif'
  ctx.fillText(branding.businessName, 430, 235, 1180)
  ctx.font = '700 52px Georgia, serif'
  ctx.fillText(branding.outletName !== branding.businessName ? branding.outletName : 'Kebab & Coffee', 435, 315, 1120)

  ctx.textAlign = 'center'
  ctx.fillStyle = ink
  ctx.font = '700 68px Georgia, serif'
  ctx.fillText('SCAN QR', 874, 485, 1450)
  ctx.fillText('UNTUK MEMESAN', 874, 570, 1450)

  // Panel nomor meja dibuat dominan agar mudah dibaca dari kejauhan.
  ctx.fillStyle = red
  ctx.beginPath()
  ctx.moveTo(150, 1745)
  ctx.lineTo(1598, 1745)
  ctx.lineTo(1558, 1900)
  ctx.lineTo(1598, 2165)
  ctx.lineTo(150, 2165)
  ctx.closePath()
  ctx.fill()
  ctx.strokeStyle = darkRed
  ctx.lineWidth = 18
  ctx.stroke()
  ctx.strokeStyle = gold
  ctx.lineWidth = 8
  ctx.stroke()
  ctx.fillStyle = '#e7c476'
  ctx.font = '700 180px Georgia, serif'
  ctx.fillText(tableLabel(table.table_number).toUpperCase(), 874, 1985, 1300)
  if (table.area?.trim()) {
    ctx.fillStyle = ivory
    ctx.font = '500 40px Georgia, serif'
    ctx.fillText(`AREA ${table.area.trim().toUpperCase()}`, 874, 2090, 1200)
  }

  const qrImage = await loadImage(dataUrl)
  ctx.fillStyle = '#fffdf7'
  ctx.fillRect(334, 650, 1080, 1080)
  ctx.strokeStyle = gold
  ctx.lineWidth = 14
  ctx.strokeRect(334, 650, 1080, 1080)
  ctx.lineWidth = 4
  ctx.strokeRect(370, 686, 1008, 1008)
  ctx.drawImage(qrImage, 424, 740, 900, 900)

  const footer = [branding.address, branding.phone].filter(Boolean).join(' • ')
  ctx.strokeStyle = gold
  ctx.lineWidth = 5
  ctx.beginPath()
  ctx.moveTo(100, 2280)
  ctx.lineTo(1648, 2280)
  ctx.stroke()
  if (footer) {
    ctx.fillStyle = ink
    ctx.font = '400 32px Georgia, serif'
    ctx.fillText(footer, 874, 2370, 1480)
  }

  const a = document.createElement('a')
  a.href = canvas.toDataURL('image/png', 1)
  a.download = `qr-${tableLabel(table.table_number).toLowerCase().replace(/\s+/g, '-')}.png`
  a.click()
}

function printQR(dataUrl: string, table: RestaurantTable, branding: QRBranding): boolean {
  if (!isQrPngDataUrl(dataUrl)) throw new Error('Data QR tidak valid. Buat ulang QR Code meja ini.')
  const win = window.open('', '_blank')
  if (!win) return false
  win.opener = null
  // dataUrl sudah dibatasi ke PNG base64; seluruh data outlet di-escape.
  const safeQr = escapeHtml(dataUrl)
  const safeTable = escapeHtml(tableLabel(table.table_number))
  const safeArea = escapeHtml(table.area?.trim() ?? '')
  const safeBusiness = escapeHtml(branding.businessName)
  const safeOutlet = escapeHtml(branding.outletName)
  const safeAddress = escapeHtml(branding.address)
  const safePhone = escapeHtml(branding.phone)
  const safeLogo = safeImageUrl(branding.logoUrl)
  win.document.write(`
    <!doctype html>
    <html lang="id">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width,initial-scale=1" />
        <title>QR Code ${safeTable}</title>
        <style>
          @page { size: A5 portrait; margin: 0; }
          * { box-sizing: border-box; }
          html, body { margin: 0; min-height: 100%; }
          body {
            display: grid;
            place-items: center;
            background: #d9d9d9;
            color: #30271c;
            font-family: Georgia, "Times New Roman", serif;
            -webkit-print-color-adjust: exact;
            print-color-adjust: exact;
          }
          .poster {
            position: relative;
            width: 148mm;
            height: 210mm;
            overflow: hidden;
            padding: 8mm 9mm 7mm;
            background:
              radial-gradient(circle at 50% 42%, rgba(255,255,255,.82), rgba(197,161,90,.08)),
              #fbf8ef;
            border: .35mm solid rgba(197,161,90,.55);
          }
          .top { min-height: 25mm; }
          .brand { display: flex; align-items: center; justify-content: center; gap: 4mm; }
          .brand-logo {
            width: 23mm; height: 23mm; border-radius: 50%; object-fit: cover;
          }
          .brand-copy { text-align: left; }
          .business { margin: 0; font-size: 8mm; line-height: 1; font-weight: 700; }
          .outlet { margin-top: 1.2mm; font-size: 4.3mm; font-weight: 700; }
          .scan-heading { margin-top: 5mm; text-align: center; font-size: 7mm; line-height: 1.08; font-weight: 700; }
          .main { display: flex; flex-direction: column; align-items: center; gap: 6mm; margin-top: 5mm; }
          .table-panel {
            display: grid; place-content: center; width: 100%; min-height: 34mm;
            text-align: center; color: #fbf8ef; background: #9f1d20;
            border: 1.8mm solid #761317; outline: .8mm solid #c5a15a; outline-offset: -3.2mm;
            clip-path: polygon(0 0, 100% 0, 97% 42%, 100% 100%, 0 100%);
          }
          .table-number { margin: 0; color: #e7c476; font-size: 15mm; line-height: 1; font-weight: 700; }
          .area { min-height: 4mm; margin-top: 1.8mm; font-size: 3.1mm; }
          .qr-shell {
            width: 88mm; height: 88mm; margin: auto; padding: 6mm; background: #fffdf7;
            border: 1.2mm solid #c5a15a; outline: .35mm solid #c5a15a; outline-offset: -3mm;
          }
          .qr { display: block; width: 76mm; height: 76mm; margin: auto; }
          .footer { min-height: 8mm; margin-top: 6mm; padding-top: 3mm; border-top: .45mm solid #c5a15a; text-align: center; font-size: 3mm; line-height: 1.4; }
          @media print {
            body { background: #fff; }
            .poster { width: 148mm; height: 210mm; }
          }
        </style>
      </head>
      <body>
        <main class="poster">
          <header class="top">
            <div class="brand">
              ${safeLogo ? `<img class="brand-logo" src="${safeLogo}" alt="Logo ${safeBusiness}" />` : ''}
              <div class="brand-copy">
                <h1 class="business">${safeBusiness}</h1>
                <div class="outlet">${safeOutlet && safeOutlet !== safeBusiness ? safeOutlet : 'Kebab &amp; Coffee'}</div>
              </div>
            </div>
          </header>
          <div class="scan-heading">SCAN QR<br />UNTUK MEMESAN</div>
          <section class="main">
            <div class="qr-shell"><img class="qr" src="${safeQr}" alt="QR ${safeTable}" /></div>
            <div class="table-panel">
              <h2 class="table-number">${safeTable.toUpperCase()}</h2>
              <div class="area">${safeArea ? `AREA ${safeArea.toUpperCase()}` : '&nbsp;'}</div>
            </div>
          </section>
          ${(safeAddress || safePhone) ? `<footer class="footer">${safeAddress}${safeAddress && safePhone ? ' &nbsp;•&nbsp; ' : ''}${safePhone}</footer>` : '<footer class="footer">&nbsp;</footer>'}
        </main>
        <script>
          window.addEventListener('load', function () {
            setTimeout(function () { window.print() }, 150)
          })
          window.addEventListener('afterprint', function () { window.close() })
        </script>
      </body>
    </html>
  `)
  win.document.close()
  return true
}

export default function QRManager() {
  const { activeOutletId, activeOutlet } = useOutlet()
  const {
    data: tables = [],
    isLoading,
    isError,
    error: tablesError,
    refetch: refetchTables,
  } = useTables(activeOutletId ?? '')
  const [preview, setPreview] = useState<{ table: RestaurantTable; url: string } | null>(null)
  const [generating, setGenerating] = useState<string | null>(null)
  const [pendingRegenerate, setPendingRegenerate] = useState<RestaurantTable | null>(null)
  const qc = useQueryClient()
  const { toast } = useToast()

  useRealtimeTables(activeOutletId)
  const branding: QRBranding = {
    businessName: activeOutlet?.settings?.business_name?.trim() || activeOutlet?.name?.trim() || 'QR Ordering',
    outletName: activeOutlet?.name?.trim() || 'QR Ordering',
    address: [activeOutlet?.address?.trim(), activeOutlet?.city?.trim()].filter(Boolean).join(', '),
    phone: activeOutlet?.phone?.trim() || '',
    logoUrl: activeOutlet?.settings?.receipt_logo_url || activeOutlet?.logo_url || logo,
  }

  async function generateQR(table: RestaurantTable) {
    if (!activeOutletId || table.outlet_id !== activeOutletId) {
      toast({ title: 'Meja tidak valid', description: 'Muat ulang halaman lalu pilih outlet kembali.', variant: 'destructive' })
      return
    }
    if (!table.is_active) {
      toast({ title: 'Meja tidak aktif', description: 'Aktifkan meja sebelum membuat QR Code.', variant: 'destructive' })
      return
    }

    setGenerating(table.id)
    try {
      // Setiap generate/regenerate merotasi token. QR lama langsung tidak valid.
      const token = crypto.randomUUID()
      const menuUrl = buildMenuUrl(token)

      // Generate QR sebagai data URL (PNG)
      const dataUrl = await QRCode.toDataURL(menuUrl, {
        width: 400,
        margin: 2,
        color: { dark: '#111827', light: '#ffffff' },
      })

      // Simpan token + URL secara atomik, lalu pastikan baris benar-benar berubah.
      const generatedAt = new Date().toISOString()
      const { data: savedTable, error } = await supabase
        .from('restaurant_tables')
        .update({
          qr_token: token,
          qr_code_url: dataUrl,
          qr_generated_at: generatedAt,
        })
        .eq('id', table.id)
        .eq('outlet_id', activeOutletId)
        .eq('is_active', true)
        .select('*')
        .single()

      if (error) throw error
      if (!savedTable?.id) throw new Error('Perubahan QR tidak tersimpan.')

      await qc.invalidateQueries({ queryKey: ['tables', activeOutletId] })
      setPreview({ table: savedTable as RestaurantTable, url: dataUrl })
      toast({
        title: table.qr_token ? 'QR Code baru berhasil dibuat' : 'QR Code berhasil dibuat',
        description: table.qr_token ? 'QR Code sebelumnya sudah tidak dapat digunakan.' : undefined,
      })
    } catch (e) {
      toast({ title: 'Gagal membuat QR', description: humanizeError(e), variant: 'destructive' })
    } finally {
      setGenerating(null)
    }
  }

  async function downloadQR(dataUrl: string, table: RestaurantTable) {
    try {
      await downloadQRPoster(dataUrl, table, branding)
    } catch (error) {
      toast({
        title: 'Gagal mengunduh desain QR',
        description: error instanceof Error ? error.message : 'Gambar tidak dapat dibuat.',
        variant: 'destructive',
      })
    }
  }

  if (!activeOutletId) return <NoOutlet />

  return (
    <div className="space-y-4">
      <PageHeader
        title="QR Code Meja"
        subtitle={`${tables.length} meja terdaftar · Generate dan kelola QR code untuk setiap meja`}
      />

      {isError ? (
        <div className="flex flex-col items-center justify-center gap-3 rounded-xl border border-red-200 bg-red-50 px-5 py-10 text-center">
          <AlertCircle className="h-7 w-7 text-red-600" />
          <div>
            <p className="font-semibold text-red-900">Daftar meja gagal dimuat</p>
            <p className="mt-1 text-sm text-red-700">
              {tablesError ? humanizeError(tablesError) : 'Periksa koneksi lalu coba muat ulang.'}
            </p>
          </div>
          <Button variant="outline" size="sm" onClick={() => void refetchTables()}>
            <RefreshCw className="mr-2 h-4 w-4" /> Muat Ulang
          </Button>
        </div>
      ) : (
        <DataTable
          data={tables}
          loading={isLoading}
          getRowKey={(r) => r.id}
          emptyMessage="Belum ada meja. Tambahkan meja di halaman Kelola Meja."
          columns={[
          { key: 'number', header: 'Meja', cell: (r) => <span className="font-medium">{tableLabel(r.table_number)}</span> },
          { key: 'area', header: 'Area', cell: (r) => r.area ?? '—' },
          { key: 'active', header: 'Status Meja', cell: (r) => (
            r.is_active
              ? <Badge className="bg-emerald-600 hover:bg-emerald-600">Aktif</Badge>
              : <Badge variant="secondary">Nonaktif</Badge>
          )},
          { key: 'status', header: 'QR Code', cell: (r) => {
            if (hasUsableQR(r)) return <Badge variant="default">Sudah dibuat</Badge>
            if (hasAnyQRData(r)) return <Badge variant="destructive">Perlu dibuat ulang</Badge>
            return <Badge variant="secondary">Belum ada</Badge>
          }},
          { key: 'generated', header: 'Terakhir Dibuat', cell: (r) => formatGeneratedAt(r.qr_generated_at) },
          { key: 'actions', header: '', cell: (r) => (
            <div className="flex gap-2 justify-end">
              {hasUsableQR(r) && (
                <Button variant="outline" size="sm" onClick={() => setPreview({ table: r, url: r.qr_code_url! })}>
                  <QrCode className="h-4 w-4 mr-1" /> Lihat
                </Button>
              )}
              <Button
                variant="outline"
                size="sm"
                disabled={generating !== null || !r.is_active}
                onClick={() => hasAnyQRData(r) ? setPendingRegenerate(r) : void generateQR(r)}
              >
                <RefreshCw className={`h-4 w-4 mr-1 ${generating === r.id ? 'animate-spin' : ''}`} />
                {hasUsableQR(r) ? 'Buat Ulang' : hasAnyQRData(r) ? 'Perbaiki QR' : 'Generate'}
              </Button>
            </div>
          ), className: 'text-right' },
          ]}
        />
      )}

      <Dialog open={!!preview} onOpenChange={(o) => !o && setPreview(null)}>
        <DialogContent className="max-h-[calc(100dvh-2rem)] max-w-lg overflow-y-auto p-0">
          <DialogHeader className="sr-only">
            <DialogTitle>QR Code — {preview ? tableLabel(preview.table.table_number) : ''}</DialogTitle>
          </DialogHeader>
          {preview && (
            <div>
              <div
                className="mx-auto my-3 flex aspect-[148/210] w-[calc(100%_-_1.5rem)] max-w-[26rem] flex-col border border-[#c5a15a]/50 bg-[#fbf8ef] px-5 pb-4 pt-5 text-[#30271c] shadow-inner"
                style={{ backgroundImage: 'radial-gradient(circle at 50% 42%, rgba(255,255,255,.92), rgba(197,161,90,.09))' }}
              >
                <div className="flex items-center justify-center gap-4">
                    <img
                      src={branding.logoUrl}
                      alt={`Logo ${branding.businessName}`}
                      className="h-14 w-14 shrink-0 rounded-full object-cover"
                      onError={(event) => { event.currentTarget.src = logo }}
                    />
                    <div className="text-left font-serif">
                      <p className="text-2xl font-bold leading-none">{branding.businessName}</p>
                      <p className="mt-1 text-base font-bold">
                        {branding.outletName !== branding.businessName ? branding.outletName : 'Kebab & Coffee'}
                      </p>
                    </div>
                </div>
                <p className="mt-4 text-center font-serif text-2xl font-bold leading-tight">
                  SCAN QR<br />UNTUK MEMESAN
                </p>

                <div className="mt-4 flex flex-1 flex-col items-center justify-center gap-4">
                  <div className="mx-auto w-fit border-4 border-[#c5a15a] bg-[#fffdf7] p-3 outline outline-1 -outline-offset-[9px] outline-[#c5a15a]">
                    <img
                      src={preview.url}
                      alt={`QR ${tableLabel(preview.table.table_number)}`}
                      className="h-52 w-52"
                    />
                  </div>
                  <div className="relative w-full overflow-hidden border-[5px] border-[#761317] bg-[#9f1d20] px-4 py-4 text-center font-serif text-[#fbf8ef] outline outline-2 -outline-offset-[10px] outline-[#c5a15a]">
                    <p className="text-4xl font-bold leading-none text-[#e7c476]">
                      {tableLabel(preview.table.table_number).toUpperCase()}
                    </p>
                    <p className="mt-1 min-h-4 text-xs tracking-wider">
                      {preview.table.area ? `AREA ${preview.table.area.toUpperCase()}` : ''}
                    </p>
                  </div>
                </div>
                <div className="mt-4 min-h-5 border-t-2 border-[#c5a15a] pt-2 text-center font-serif text-[11px]">
                  {[branding.address, branding.phone].filter(Boolean).join(' • ')}
                </div>
              </div>
              <div className="flex gap-2 justify-center border-t bg-white p-4">
                <Button size="sm" onClick={() => void downloadQR(preview.url, preview.table)}>
                  <Download className="h-4 w-4 mr-1" /> Unduh
                </Button>
                <Button
                  size="sm"
                  variant="outline"
                  onClick={() => {
                    try {
                      if (!printQR(preview.url, preview.table, branding)) {
                        toast({
                          title: 'Jendela cetak diblokir',
                          description: 'Izinkan pop-up untuk situs ini lalu coba kembali.',
                          variant: 'destructive',
                        })
                      }
                    } catch (error) {
                      toast({
                        title: 'Gagal mencetak QR',
                        description: error instanceof Error ? error.message : 'Data QR tidak valid.',
                        variant: 'destructive',
                      })
                    }
                  }}
                >
                  Cetak
                </Button>
              </div>
            </div>
          )}
        </DialogContent>
      </Dialog>

      <AlertDialog open={!!pendingRegenerate} onOpenChange={(open) => !open && setPendingRegenerate(null)}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>Buat ulang QR {pendingRegenerate ? tableLabel(pendingRegenerate.table_number) : ''}?</AlertDialogTitle>
            <AlertDialogDescription>
              QR Code yang sudah dicetak sebelumnya akan langsung tidak berlaku. Cetak dan pasang QR Code yang baru setelah proses selesai.
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>Batal</AlertDialogCancel>
            <AlertDialogAction
              onClick={() => {
                const table = pendingRegenerate
                setPendingRegenerate(null)
                if (table) void generateQR(table)
              }}
            >
              Ya, Buat Ulang
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </div>
  )
}

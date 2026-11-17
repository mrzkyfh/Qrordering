import { useForm } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import { z } from 'zod'
import { useOutlet } from '@/hooks/useOutlet'
import { useUpdateOutlet } from '@/hooks/queries/useOutlets'
import { PageHeader } from '@/components/ui/PageHeader'
import { NoOutlet } from '@/components/ui/NoOutlet'
import { Form, FormControl, FormField, FormItem, FormLabel, FormMessage } from '@/components/ui/form'
import { Input } from '@/components/ui/input'
import { Textarea } from '@/components/ui/textarea'
import { Button } from '@/components/ui/button'
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
import { useToast } from '@/hooks/use-toast'
import { humanizeError } from '@/lib/errorMessage'
import { useEffect } from 'react'

const infoSchema = z.object({
  name: z.string().min(2, 'Nama wajib diisi'),
  address: z.string().optional(),
  phone: z.string().optional(),
  city: z.string().optional(),
})

const configSchema = z.object({
  receipt_footer: z.string().optional(),
})

const customerMenuSchema = z.object({
  customer_menu_cover_url: z.string().trim().refine((value) => {
    if (!value) return true
    try {
      return new URL(value).protocol === 'https:'
    } catch {
      return false
    }
  }, 'Gunakan URL gambar HTTPS yang valid'),
})

type InfoValues = z.infer<typeof infoSchema>
type ConfigValues = z.infer<typeof configSchema>
type CustomerMenuValues = z.infer<typeof customerMenuSchema>

export default function Settings() {
  const { activeOutlet, activeOutletId } = useOutlet()
  const updateOutlet = useUpdateOutlet()
  const { toast } = useToast()

  const infoForm = useForm<InfoValues>({
    resolver: zodResolver(infoSchema),
    defaultValues: { name: '', address: '', phone: '', city: '' },
  })

  const configForm = useForm<ConfigValues>({
    resolver: zodResolver(configSchema),
    defaultValues: { receipt_footer: '' },
  })

  const customerMenuForm = useForm<CustomerMenuValues>({
    resolver: zodResolver(customerMenuSchema),
    defaultValues: { customer_menu_cover_url: '' },
  })

  useEffect(() => {
    if (!activeOutlet) return
    infoForm.reset({ name: activeOutlet.name, address: activeOutlet.address ?? '', phone: activeOutlet.phone ?? '', city: activeOutlet.city ?? '' })
    configForm.reset({
      receipt_footer: activeOutlet.settings?.receipt_footer ?? '',
    })
    customerMenuForm.reset({
      customer_menu_cover_url: activeOutlet.settings?.customer_menu_cover_url ?? '',
    })
  }, [activeOutlet])  // eslint-disable-line react-hooks/exhaustive-deps

  async function saveInfo(values: InfoValues) {
    if (!activeOutletId) return
    updateOutlet.mutate({ id: activeOutletId, updates: { name: values.name, address: values.address || null, phone: values.phone || null, city: values.city || null } }, {
      onSuccess: () => toast({ title: 'Info outlet disimpan' }),
      onError: (e) => toast({ title: 'Gagal', description: humanizeError(e), variant: 'destructive' }),
    })
  }

  async function saveConfig(values: ConfigValues) {
    if (!activeOutletId || !activeOutlet) return
    const settings = {
      ...activeOutlet.settings,
      receipt_footer: values.receipt_footer ?? '',
    }
    updateOutlet.mutate({ id: activeOutletId, updates: { settings } }, {
      onSuccess: () => toast({ title: 'Konfigurasi disimpan' }),
      onError: (e) => toast({ title: 'Gagal', description: humanizeError(e), variant: 'destructive' }),
    })
  }

  async function saveCustomerMenu(values: CustomerMenuValues) {
    if (!activeOutletId || !activeOutlet) return
    const settings = {
      ...activeOutlet.settings,
      customer_menu_cover_url: values.customer_menu_cover_url || null,
    }
    updateOutlet.mutate({ id: activeOutletId, updates: { settings } }, {
      onSuccess: () => toast({ title: 'Tampilan customer menu disimpan' }),
      onError: (e) => toast({ title: 'Gagal', description: humanizeError(e), variant: 'destructive' }),
    })
  }

  if (!activeOutletId) return <NoOutlet />

  return (
    <div className="space-y-4">
      <PageHeader title="Pengaturan Outlet" />

      <div className="max-w-2xl space-y-4">
        <Card>
          <CardHeader><CardTitle className="text-base">Informasi Outlet</CardTitle></CardHeader>
          <CardContent>
            <Form {...infoForm}>
              <form onSubmit={infoForm.handleSubmit(saveInfo)} className="space-y-4">
                <FormField control={infoForm.control} name="name" render={({ field }) => (
                  <FormItem><FormLabel>Nama Outlet</FormLabel><FormControl><Input {...field} /></FormControl><FormMessage /></FormItem>
                )} />
                <FormField control={infoForm.control} name="address" render={({ field }) => (
                  <FormItem><FormLabel>Alamat</FormLabel><FormControl><Textarea rows={2} {...field} /></FormControl><FormMessage /></FormItem>
                )} />
                <div className="grid grid-cols-2 gap-4">
                  <FormField control={infoForm.control} name="phone" render={({ field }) => (
                    <FormItem><FormLabel>Telepon</FormLabel><FormControl><Input type="tel" {...field} /></FormControl><FormMessage /></FormItem>
                  )} />
                  <FormField control={infoForm.control} name="city" render={({ field }) => (
                    <FormItem><FormLabel>Kota</FormLabel><FormControl><Input {...field} /></FormControl><FormMessage /></FormItem>
                  )} />
                </div>
                <Button type="submit" disabled={updateOutlet.isPending}>{updateOutlet.isPending ? 'Menyimpan...' : 'Simpan'}</Button>
              </form>
            </Form>
          </CardContent>
        </Card>

        <Card>
          <CardHeader><CardTitle className="text-base">Tampilan Customer Menu</CardTitle></CardHeader>
          <CardContent>
            <Form {...customerMenuForm}>
              <form onSubmit={customerMenuForm.handleSubmit(saveCustomerMenu)} className="space-y-4">
                <FormField control={customerMenuForm.control} name="customer_menu_cover_url" render={({ field }) => (
                  <FormItem>
                    <FormLabel>URL Foto Sampul</FormLabel>
                    <FormControl>
                      <Input
                        type="url"
                        inputMode="url"
                        placeholder="https://.../foto-outlet.jpg"
                        autoComplete="url"
                        {...field}
                      />
                    </FormControl>
                    <p className="text-xs text-muted-foreground">
                      Ditampilkan di halaman pembuka QR order. Kosongkan untuk memakai foto menu pertama.
                    </p>
                    <FormMessage />
                  </FormItem>
                )} />
                <Button type="submit" disabled={updateOutlet.isPending}>{updateOutlet.isPending ? 'Menyimpan...' : 'Simpan'}</Button>
              </form>
            </Form>
          </CardContent>
        </Card>

        <Card>
          <CardHeader><CardTitle className="text-base">Footer Struk</CardTitle></CardHeader>
          <CardContent>
            <Form {...configForm}>
              <form onSubmit={configForm.handleSubmit(saveConfig)} className="space-y-4">
                <FormField control={configForm.control} name="receipt_footer" render={({ field }) => (
                  <FormItem>
                    <FormLabel>Teks Footer</FormLabel>
                    <FormControl><Textarea rows={3} placeholder="Terima kasih telah berkunjung!" {...field} /></FormControl>
                    <FormMessage />
                  </FormItem>
                )} />
                <Button type="submit" disabled={updateOutlet.isPending}>{updateOutlet.isPending ? 'Menyimpan...' : 'Simpan'}</Button>
              </form>
            </Form>
          </CardContent>
        </Card>
      </div>
    </div>
  )
}

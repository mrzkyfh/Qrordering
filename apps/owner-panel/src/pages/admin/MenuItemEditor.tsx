import { ArrowLeft } from 'lucide-react'
import { useNavigate, useParams } from 'react-router'
import { useOutlet } from '@/hooks/useOutlet'
import { useMenuCategories, useMenuItems } from '@/hooks/queries/useMenuItems'
import { useExtras } from '@/hooks/queries/useExtras'
import { MenuItemForm } from '@/pages/admin/MenuManager'
import { PageHeader } from '@/components/ui/PageHeader'
import { NoOutlet } from '@/components/ui/NoOutlet'
import { Button } from '@/components/ui/button'
import { Card, CardContent } from '@/components/ui/card'

export default function MenuItemEditor() {
  const { activeOutletId } = useOutlet()
  const { menuItemId } = useParams<{ menuItemId?: string }>()
  const navigate = useNavigate()
  const isEditing = Boolean(menuItemId)
  const categoriesQuery = useMenuCategories(activeOutletId ?? '')
  const extrasQuery = useExtras(activeOutletId ?? '')
  const itemsQuery = useMenuItems(activeOutletId ?? '')
  const item = isEditing
    ? itemsQuery.data?.find((menuItem) => menuItem.id === menuItemId)
    : undefined

  if (!activeOutletId) return <NoOutlet />

  const isLoading = categoriesQuery.isLoading
    || extrasQuery.isLoading
    || (isEditing && itemsQuery.isLoading)

  if (isLoading) {
    return (
      <div className="space-y-4">
        <PageHeader title={isEditing ? 'Edit Menu' : 'Tambah Menu'} />
        <Card className="max-w-4xl">
          <CardContent className="space-y-4 p-6">
            <div className="h-40 animate-pulse rounded-lg bg-muted" />
            <div className="h-10 animate-pulse rounded-lg bg-muted" />
            <div className="h-10 animate-pulse rounded-lg bg-muted" />
          </CardContent>
        </Card>
      </div>
    )
  }

  if (isEditing && !item) {
    return (
      <div className="space-y-4">
        <PageHeader title="Menu Tidak Ditemukan" />
        <Card className="max-w-4xl">
          <CardContent className="space-y-4 p-6">
            <p className="text-sm text-muted-foreground">
              Produk yang ingin diedit tidak tersedia atau sudah dihapus.
            </p>
            <Button variant="outline" onClick={() => navigate('/admin/menu')}>
              <ArrowLeft className="mr-2 h-4 w-4" /> Kembali ke Daftar Menu
            </Button>
          </CardContent>
        </Card>
      </div>
    )
  }

  return (
    <div className="space-y-4">
      <PageHeader title={isEditing ? 'Edit Menu' : 'Tambah Menu Baru'}>
        <Button variant="outline" onClick={() => navigate('/admin/menu')}>
          <ArrowLeft className="mr-2 h-4 w-4" /> Kembali
        </Button>
      </PageHeader>

      <Card className="max-w-4xl">
        <CardContent className="p-4 sm:p-6">
          <MenuItemForm
            outletId={activeOutletId}
            categories={categoriesQuery.data ?? []}
            extras={extrasQuery.data ?? []}
            item={item}
            onClose={() => navigate('/admin/menu')}
          />
        </CardContent>
      </Card>
    </div>
  )
}

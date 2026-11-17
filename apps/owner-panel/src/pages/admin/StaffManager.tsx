import { useQuery } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import { useOutlet } from '@/hooks/useOutlet'
import { useAuth } from '@/hooks/useAuth'
import { PageHeader } from '@/components/ui/PageHeader'
import { NoOutlet } from '@/components/ui/NoOutlet'
import { DataTable } from '@/components/ui/DataTable'
import { Badge } from '@/components/ui/badge'
import { format } from 'date-fns'
import { id } from 'date-fns/locale'
import {
  PROFILE_SELECT_COLUMNS,
  type Profile,
  type UserRole,
} from '@/types/database'

const ROLE_LABELS: Record<UserRole, string> = {
  owner: 'Owner', admin: 'Admin', manajer: 'Manajer', kasir: 'Kasir', pelanggan: 'Pelanggan',
}

const VISIBLE_ROLES: UserRole[] = ['manajer', 'kasir']
const OWNER_VISIBLE_ROLES: UserRole[] = ['owner', 'admin', 'manajer', 'kasir']

function useStaff(outletId: string, roles: UserRole[]) {
  return useQuery({
    queryKey: ['staff', outletId, roles],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('profiles').select(PROFILE_SELECT_COLUMNS)
        .eq('outlet_id', outletId)
        .in('role', roles)
        .order('full_name')
      if (error) throw error
      return data as Profile[]
    },
    enabled: !!outletId,
  })
}

export default function AdminStaffManager() {
  const { activeOutletId } = useOutlet()
  const { isOwner } = useAuth()
  const roles = isOwner() ? OWNER_VISIBLE_ROLES : VISIBLE_ROLES
  const { data: staff = [], isLoading } = useStaff(activeOutletId ?? '', roles)

  if (!activeOutletId) return <NoOutlet />

  return (
    <div className="space-y-4">
      <PageHeader title="Manajemen Staff" subtitle="Staff dapat ditambahkan melalui panel Owner atau Supabase Auth." />
      <DataTable
        data={staff}
        loading={isLoading}
        getRowKey={(r) => r.id}
        emptyMessage="Belum ada staff terdaftar."
        columns={[
          { key: 'name', header: 'Nama', cell: (r) => <span className="font-medium">{r.full_name}</span> },
          { key: 'role', header: 'Role', cell: (r) => <Badge variant="outline">{ROLE_LABELS[r.role]}</Badge> },
          { key: 'phone', header: 'Telepon', cell: (r) => r.phone ?? '—' },
          { key: 'status', header: 'Status', cell: (r) => <Badge variant={r.is_active ? 'default' : 'secondary'}>{r.is_active ? 'Aktif' : 'Nonaktif'}</Badge> },
          { key: 'login', header: 'Login Terakhir', cell: (r) => r.last_login_at ? format(new Date(r.last_login_at), 'd MMM yyyy', { locale: id }) : 'Belum pernah' },
        ]}
      />
    </div>
  )
}

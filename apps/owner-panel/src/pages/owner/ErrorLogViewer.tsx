import { useState } from 'react'
import { format } from 'date-fns'
import { id } from 'date-fns/locale'
import { useErrorLogs, type ErrorLog } from '@/hooks/queries/useErrorLogs'
import { PageHeader } from '@/components/ui/PageHeader'
import { DataTable } from '@/components/ui/DataTable'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import {
  Dialog, DialogContent, DialogHeader, DialogTitle,
} from '@/components/ui/dialog'

export default function ErrorLogViewer() {
  const { data: logs = [], isLoading } = useErrorLogs()
  const [selected, setSelected] = useState<ErrorLog | null>(null)

  return (
    <div className="space-y-4">
      <PageHeader
        title="Log Error"
        subtitle="Error aplikasi tujuh hari terakhir. Error yang sama digabung agar basis data tidak penuh."
      />

      <DataTable
        data={logs}
        loading={isLoading}
        getRowKey={(r) => r.id}
        emptyMessage="Tidak ada error tercatat."
        columns={[
          {
            key: 'time', header: 'Waktu',
            cell: (r) => format(new Date(r.last_seen_at), 'd MMM yyyy HH:mm', { locale: id }),
          },
          {
            key: 'message', header: 'Pesan',
            cell: (r) => (
              <Button
                variant="link"
                className="block h-auto max-w-md justify-start truncate p-0 text-left font-medium text-red-600"
                onClick={() => setSelected(r)}
              >
                {r.message}
              </Button>
            ),
          },
          { key: 'platform', header: 'Platform', cell: (r) => <Badge variant="outline">{r.platform ?? '—'}</Badge> },
          { key: 'build', header: 'Build', cell: (r) => r.app_build ?? '—' },
          {
            key: 'count', header: 'Terjadi',
            cell: (r) => <Badge variant={r.occurrence_count > 1 ? 'destructive' : 'secondary'}>{r.occurrence_count} kali</Badge>,
          },
          { key: 'user', header: 'User', cell: (r) => r.user_name ?? '—' },
        ]}
      />

      <Dialog open={!!selected} onOpenChange={(o) => !o && setSelected(null)}>
        <DialogContent className="w-[calc(100vw-2rem)] max-w-2xl min-w-0 overflow-hidden">
          <DialogHeader className="min-w-0">
            <DialogTitle className="max-h-40 min-w-0 overflow-y-auto break-all pr-6 text-red-600">
              {selected?.message}
            </DialogTitle>
          </DialogHeader>
          <pre className="max-h-[60vh] max-w-full overflow-auto whitespace-pre-wrap break-all rounded-lg border bg-gray-50 p-3 text-xs">
            {selected?.stack ?? 'Tidak ada stack trace.'}
          </pre>
        </DialogContent>
      </Dialog>
    </div>
  )
}

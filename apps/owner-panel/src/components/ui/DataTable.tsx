import type { ReactNode } from 'react'
import { Skeleton } from '@/components/ui/skeleton'
import { Button } from '@/components/ui/button'
import { ChevronLeft, ChevronRight } from 'lucide-react'

export interface Column<T> {
  key: string
  header: string
  cell: (row: T, index?: number) => ReactNode
  className?: string
  headerClassName?: string
}

interface DataTableProps<T> {
  data: T[]
  columns: Column<T>[]
  loading?: boolean
  emptyMessage?: string
  pageSize?: number
  page?: number
  totalCount?: number
  onPageChange?: (page: number) => void
  getRowKey: (row: T) => string
  scrollable?: boolean
}

export function DataTable<T>({
  data,
  columns,
  loading = false,
  emptyMessage = 'Tidak ada data.',
  pageSize = 20,
  page = 1,
  totalCount,
  onPageChange,
  getRowKey,
  scrollable = true,
}: DataTableProps<T>) {
  const totalPages = totalCount ? Math.ceil(totalCount / pageSize) : undefined

  if (loading) {
    return (
      <div className="bg-white rounded-xl border border-gray-100 shadow-sm p-4 space-y-2">
        {Array.from({ length: 5 }).map((_, i) => (
          <Skeleton key={i} className="h-9 w-full rounded" />
        ))}
      </div>
    )
  }

  return (
    <div className="w-full min-w-0 space-y-3">
      {/* Desktop / tablet: tabel biasa (scroll horizontal bila sempit) */}
      <div className="hidden md:block bg-white rounded-2xl border border-[#E5E7EB] shadow-sm overflow-hidden">
        <div className={scrollable ? 'overflow-x-auto' : ''}>
          <table className="w-full min-w-[900px] text-sm">
            <thead>
              <tr className="border-b bg-gray-50">
                {columns.map((col) => (
                  <th
                    key={col.key}
                    scope="col"
                    className={`px-5 py-3 text-xs font-semibold text-muted-foreground uppercase tracking-wider text-left whitespace-nowrap ${col.headerClassName ?? ''}`}
                  >
                    {col.header}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {data.length === 0 ? (
                <tr>
                  <td
                    colSpan={columns.length}
                    className="h-24 text-center text-sm text-muted-foreground px-5 py-8"
                  >
                    {emptyMessage}
                  </td>
                </tr>
              ) : (
                data.map((row, rowIndex) => (
                  <tr
                    key={getRowKey(row)}
                    className={`border-b last:border-0 hover:bg-gray-50/60 transition-colors ${rowIndex % 2 !== 0 ? 'bg-gray-50/30' : ''}`}
                  >
                    {columns.map((col) => (
                      <td key={col.key} className={`px-5 py-3.5 text-gray-700 ${col.className ?? ''}`}>
                        {col.cell(row, rowIndex)}
                      </td>
                    ))}
                  </tr>
                ))
              )}
            </tbody>
          </table>
        </div>
      </div>

      {/* Mobile: tiap baris jadi kartu label:value */}
      <div className="w-full min-w-0 space-y-2.5 md:hidden">
        {data.length === 0 ? (
          <div className="bg-white rounded-xl border border-gray-100 shadow-sm h-24 flex items-center justify-center text-sm text-muted-foreground px-4">
            {emptyMessage}
          </div>
        ) : (
          data.map((row, rowIndex) => {
            // Kolom tanpa header (mis. tombol aksi) diletakkan di footer kartu.
            const labeled = columns.filter((c) => c.header.trim() !== '')
            const actions = columns.filter((c) => c.header.trim() === '')
            return (
              <div
                key={getRowKey(row)}
                className="w-full min-w-0 max-w-full rounded-xl border border-gray-100 bg-white p-3.5 shadow-sm"
              >
                <div className="divide-y divide-gray-100">
                  {labeled.map((col) => (
                    <div
                      key={col.key}
                      className="grid min-w-0 grid-cols-[minmax(0,0.9fr)_minmax(0,1.1fr)] items-start gap-3 py-2 first:pt-0 last:pb-0"
                    >
                      <span className="min-w-0 break-words pt-0.5 text-xs font-semibold uppercase tracking-wide text-muted-foreground">
                        {col.header}
                      </span>
                      <div className="min-w-0 max-w-full break-words text-right text-sm text-gray-700 [overflow-wrap:anywhere]">
                        {col.cell(row, rowIndex)}
                      </div>
                    </div>
                  ))}
                </div>
                {actions.length > 0 && (
                  <div className="flex justify-end gap-1 pt-1 border-t border-gray-50">
                    {actions.map((col) => (
                      <div key={col.key}>{col.cell(row, rowIndex)}</div>
                    ))}
                  </div>
                )}
              </div>
            )
          })
        )}
      </div>

      {totalPages && totalPages > 1 && onPageChange && (
        <div className="flex items-center justify-between">
          <p className="text-sm text-muted-foreground">
            Halaman {page} dari {totalPages}
          </p>
          <div className="flex gap-1">
            <Button
              variant="outline"
              size="icon-sm"
              disabled={page <= 1}
              onClick={() => onPageChange(page - 1)}
              aria-label="Halaman sebelumnya"
            >
              <ChevronLeft className="h-4 w-4" />
            </Button>
            <Button
              variant="outline"
              size="icon-sm"
              disabled={page >= totalPages}
              onClick={() => onPageChange(page + 1)}
              aria-label="Halaman berikutnya"
            >
              <ChevronRight className="h-4 w-4" />
            </Button>
          </div>
        </div>
      )}
    </div>
  )
}

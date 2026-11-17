import { Badge } from '@/components/ui/badge'
import type { OrderStatus, TableStatus } from '@/types/database'
import { cn } from '@/lib/utils'

type StatusBadgeStatus = OrderStatus | TableStatus | 'low' | 'critical' | 'out_of_stock' | 'ok'

const statusConfig: Record<StatusBadgeStatus, { label: string; className: string }> = {
  // Order statuses
  draft:         { label: 'Draft',        className: 'bg-muted text-muted-foreground' },
  confirmed:     { label: 'Dikonfirmasi', className: 'bg-blue-100 text-blue-800' },
  preparing:     { label: 'Dimasak',      className: 'bg-yellow-100 text-yellow-800' },
  ready:         { label: 'Siap',         className: 'bg-green-100 text-green-800' },
  served:        { label: 'Disajikan',    className: 'bg-green-200 text-green-900' },
  paid:          { label: 'Lunas',        className: 'bg-gray-100 text-gray-700' },
  cancelled:     { label: 'Dibatalkan',   className: 'bg-red-100 text-red-700' },
  void:          { label: 'Void',         className: 'bg-red-200 text-red-900' },
  // Table statuses
  available:     { label: 'Tersedia',     className: 'bg-green-100 text-green-800' },
  occupied:      { label: 'Terisi',       className: 'bg-red-100 text-red-800' },
  reserved:      { label: 'Reservasi',    className: 'bg-yellow-100 text-yellow-800' },
  dirty:         { label: 'Kotor',        className: 'bg-gray-200 text-gray-700' },
  // Stock statuses
  ok:            { label: 'Aman',         className: 'bg-green-100 text-green-800' },
  low:           { label: 'Hampir Habis', className: 'bg-yellow-100 text-yellow-800' },
  critical:      { label: 'Kritis',       className: 'bg-orange-100 text-orange-800' },
  out_of_stock:  { label: 'Habis',        className: 'bg-red-100 text-red-800' },
}

interface StatusBadgeProps {
  status: StatusBadgeStatus
  className?: string
}

export function StatusBadge({ status, className }: StatusBadgeProps) {
  const config = statusConfig[status] ?? { label: status, className: '' }
  return (
    <Badge className={cn('font-medium border-0', config.className, className)}>
      {config.label}
    </Badge>
  )
}

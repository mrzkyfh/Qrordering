import { formatCurrency } from '@/lib/currency'

interface CurrencyDisplayProps {
  value: number
  className?: string
}

export function CurrencyDisplay({ value, className }: CurrencyDisplayProps) {
  return <span className={className}>{formatCurrency(value)}</span>
}

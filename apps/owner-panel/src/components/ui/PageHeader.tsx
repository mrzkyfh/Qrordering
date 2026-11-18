import type { ReactNode } from 'react'
import { cn } from '@/lib/utils'

interface PageHeaderProps {
  title: string
  subtitle?: string
  children?: ReactNode
  className?: string
}

export function PageHeader({ title, subtitle, children, className }: PageHeaderProps) {
  return (
    <div className={cn('flex flex-col items-stretch gap-4 mb-6 sm:flex-row sm:items-start sm:justify-between', className)}>
      <div className="min-w-0">
        <h1 className="text-[26px] leading-8 font-bold tracking-tight text-[#1F2328]">{title}</h1>
        {subtitle && (
          <p className="text-sm text-[#6B7280] mt-1">{subtitle}</p>
        )}
      </div>
      {children && <div className="flex flex-wrap items-center gap-2 sm:justify-end sm:shrink-0">{children}</div>}
    </div>
  )
}

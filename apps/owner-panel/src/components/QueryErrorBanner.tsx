import { useCallback, useSyncExternalStore } from 'react'
import { AlertTriangle, RefreshCw } from 'lucide-react'
import { useIsFetching, useQueryClient } from '@tanstack/react-query'
import { Button } from '@/components/ui/button'

export function QueryErrorBanner() {
  const queryClient = useQueryClient()
  const isFetching = useIsFetching() > 0
  const queryCache = queryClient.getQueryCache()

  const subscribe = useCallback(
    (onStoreChange: () => void) => queryCache.subscribe(onStoreChange),
    [queryCache],
  )
  const getSnapshot = useCallback(
    () =>
      queryCache
      .getAll()
        .some((query) => query.getObserversCount() > 0 && query.state.status === 'error'),
    [queryCache],
  )
  const hasActiveError = useSyncExternalStore(subscribe, getSnapshot, getSnapshot)

  if (!hasActiveError) return null

  return (
    <div
      role="alert"
      className="mb-4 flex flex-col gap-3 rounded-lg border border-destructive/30 bg-destructive/5 p-3 text-sm sm:flex-row sm:items-center sm:justify-between"
    >
      <div className="flex items-start gap-2">
        <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0 text-destructive" />
        <div>
          <p className="font-medium">Sebagian data gagal dimuat</p>
          <p className="text-xs text-muted-foreground">
            Periksa koneksi internet, lalu coba muat ulang data.
          </p>
        </div>
      </div>
      <Button
        type="button"
        variant="outline"
        size="sm"
        className="shrink-0"
        disabled={isFetching}
        onClick={() => queryClient.refetchQueries({ type: 'active' })}
      >
        <RefreshCw className={isFetching ? 'animate-spin' : ''} />
        {isFetching ? 'Memuat...' : 'Coba Lagi'}
      </Button>
    </div>
  )
}

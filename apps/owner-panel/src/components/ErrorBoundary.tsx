import { Component, type ReactNode } from 'react'
import { Button } from '@/components/ui/button'

interface Props { children: ReactNode }
interface State { error: Error | null }

export class ErrorBoundary extends Component<Props, State> {
  state: State = { error: null }

  static getDerivedStateFromError(error: Error): State {
    return { error }
  }

  componentDidCatch(error: Error) {
    console.error('[ErrorBoundary]', error)
  }

  render() {
    if (this.state.error) {
      return (
        <div className="min-h-screen flex flex-col items-center justify-center gap-4 bg-background p-6 text-center">
          <div className="flex h-14 w-14 items-center justify-center rounded-full bg-destructive/10 text-2xl" aria-hidden="true">
            ⚠
          </div>
          <div>
            <h1 className="text-2xl font-bold">Terjadi kendala</h1>
            <p className="mt-2 max-w-md text-sm text-muted-foreground">
              Halaman tidak dapat ditampilkan. Muat ulang untuk mencoba kembali.
              Jika kendala berulang, hubungi administrator.
            </p>
          </div>
          <div className="flex flex-wrap justify-center gap-2">
            <Button onClick={() => window.location.reload()}>
              Muat Ulang
            </Button>
            <Button
              variant="outline"
              onClick={() => window.location.replace('/dashboard')}
            >
              Kembali ke Dashboard
            </Button>
          </div>
        </div>
      )
    }
    return this.props.children
  }
}

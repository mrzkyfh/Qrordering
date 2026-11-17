import { resolveBackendRoute } from '@/lib/backendRoute'

async function start() {
  const loading = document.getElementById('js-loading')
  if (loading) loading.textContent = 'Memeriksa koneksi server...'

  const route = await resolveBackendRoute()
  window.__TIME420S_BACKEND_URL__ = route.url
  window.__TIME420S_BACKEND_ROUTE__ = route.kind

  await import('./main')
}

void start()

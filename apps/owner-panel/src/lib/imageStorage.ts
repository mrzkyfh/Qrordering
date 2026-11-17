import { supabase } from '@/lib/supabase'

type ImageScope = 'menu' | 'logos' | 'covers'

const maxImageDimension: Record<ImageScope, number> = {
  menu: 720,
  logos: 512,
  covers: 1600,
}

async function optimizedImage(file: File, scope: ImageScope): Promise<File> {
  if (file.type === 'image/gif' || typeof createImageBitmap !== 'function') {
    return file
  }
  try {
    const bitmap = await createImageBitmap(file)
    const maxDimension = maxImageDimension[scope]
    const scale = Math.min(1, maxDimension / Math.max(bitmap.width, bitmap.height))
    const width = Math.max(1, Math.round(bitmap.width * scale))
    const height = Math.max(1, Math.round(bitmap.height * scale))
    const canvas = document.createElement('canvas')
    canvas.width = width
    canvas.height = height
    const context = canvas.getContext('2d')
    if (!context) {
      bitmap.close()
      return file
    }
    context.drawImage(bitmap, 0, 0, width, height)
    bitmap.close()
    const blob = await new Promise<Blob | null>((resolve) =>
      canvas.toBlob(resolve, 'image/webp', 0.78),
    )
    if (!blob || blob.size >= file.size) return file
    const baseName = file.name.replace(/\.[^.]+$/, '') || 'image'
    return new File([blob], `${baseName}.webp`, {
      type: 'image/webp',
      lastModified: file.lastModified,
    })
  } catch {
    return file
  }
}

const imageBucket = 'menu-images'
const primaryOrigin = new URL(import.meta.env.VITE_SUPABASE_URL as string).origin
const stagingPublicOrigin = 'https://qrordering-r2-staging.official-b0d.workers.dev'
const productionPublicOrigin = 'https://assets.qrordering.my.id'
const productionWorkerOrigin = 'https://qrordering-r2-production.official-b0d.workers.dev'
const storageBackend = import.meta.env.VITE_IMAGE_STORAGE_BACKEND as string | undefined
const stagingApiUrl = import.meta.env.VITE_R2_STAGING_API_URL as string | undefined
const productionApiUrl = import.meta.env.VITE_R2_API_URL as string | undefined
const imageExtensions: Record<string, string> = {
  'image/jpeg': 'jpg', 'image/png': 'png', 'image/webp': 'webp', 'image/gif': 'gif',
}

function isR2Enabled(): boolean {
  return storageBackend === 'r2-staging' || storageBackend === 'r2-production'
}

function r2Config(): { apiOrigin: string; publicOrigin: string } {
  const production = storageBackend === 'r2-production'
  const apiUrl = production ? productionApiUrl : stagingApiUrl
  const expectedApiOrigin = production ? productionWorkerOrigin : null
  const publicOrigin = production ? productionPublicOrigin : stagingPublicOrigin
  if (!isR2Enabled()) throw new Error('Backend R2 tidak aktif')
  if (!apiUrl) throw new Error('API R2 belum dikonfigurasi')
  const parsed = new URL(apiUrl)
  if (
    parsed.protocol !== 'https:' ||
    (production
      ? parsed.origin !== expectedApiOrigin
      : parsed.origin !== stagingPublicOrigin)
  ) {
    throw new Error('API R2 tidak valid')
  }
  return { apiOrigin: parsed.origin, publicOrigin }
}

async function authorizationHeader(): Promise<string> {
  const { data, error } = await supabase.auth.getSession()
  if (error) throw error
  const token = data.session?.access_token
  if (!token) throw new Error('Sesi login tidak tersedia')
  return `Bearer ${token}`
}

async function r2Error(response: Response): Promise<Error> {
  const body = await response.json().catch(() => null) as { error?: string } | null
  return new Error(body?.error || `R2 request gagal (HTTP ${response.status})`)
}

export async function uploadImageAsset(
  file: File,
  outletId: string,
  scope: ImageScope = 'menu',
): Promise<string> {
  if (!/^[0-9a-f-]{36}$/i.test(outletId)) throw new Error('Outlet tidak valid')
  const uploadFile = await optimizedImage(file, scope)
  const extension = imageExtensions[uploadFile.type]
  if (!extension) throw new Error('Gunakan gambar JPG, PNG, WebP, atau GIF')
  if (uploadFile.size > 5 * 1024 * 1024) throw new Error('Ukuran gambar maksimal 5 MB')
  if (isR2Enabled()) {
    const config = r2Config()
    const response = await fetch(`${config.apiOrigin}/v1/images`, {
      method: 'POST',
      headers: {
        Authorization: await authorizationHeader(),
        'Content-Type': uploadFile.type,
        'X-Outlet-Id': outletId,
        'X-Asset-Scope': scope,
      },
      body: uploadFile,
    })
    if (!response.ok) throw await r2Error(response)
    const result = await response.json() as { key?: string; url?: string }
    if (!result.key || !result.url) throw new Error('Respons upload R2 tidak lengkap')
    const publicUrl = new URL(result.url)
    if (publicUrl.origin !== config.publicOrigin || publicUrl.pathname !== `/assets/${result.key}`) {
      throw new Error('URL publik R2 tidak valid')
    }
    return publicUrl.toString()
  }
  const path = `${outletId}/${scope}/${crypto.randomUUID()}.${extension}`
  const { error } = await supabase.storage.from(imageBucket).upload(path, uploadFile, {
    contentType: uploadFile.type,
    cacheControl: '31536000',
    upsert: false,
  })
  if (error) throw error
  const publicUrl = new URL(supabase.storage.from(imageBucket).getPublicUrl(path).data.publicUrl)
  return primaryOrigin + publicUrl.pathname
}

export async function removeImageAsset(url: string | null | undefined): Promise<void> {
  if (!url) return
  if (isR2Enabled()) {
    const config = r2Config()
    let parsed: URL
    try { parsed = new URL(url) } catch { return }
    if (parsed.origin !== config.publicOrigin) return
    const key = decodeURIComponent(parsed.pathname.replace(/^\/assets\//, ''))
    const expected = /^menu-images\/([0-9a-f-]{36})\/(menu|logos|covers)\/[0-9a-f-]{36}\.(jpg|png|webp|gif)$/i
    if (!expected.test(key)) return
    const response = await fetch(`${config.apiOrigin}/v1/images?key=${encodeURIComponent(key)}`, {
      method: 'DELETE',
      headers: { Authorization: await authorizationHeader() },
    })
    if (!response.ok) throw await r2Error(response)
    return
  }
  const prefix = `/storage/v1/object/public/${imageBucket}/`
  let parsed: URL
  try { parsed = new URL(url) } catch { return }
  const currentOrigin = new URL(supabase.storage.from(imageBucket).getPublicUrl('').data.publicUrl).origin
  if (![primaryOrigin, currentOrigin].includes(parsed.origin) || !parsed.pathname.startsWith(prefix)) return
  const path = decodeURIComponent(parsed.pathname.slice(prefix.length))
  if (!path || path.split('/').some(part => !part || part === '..' || part === '.')) return
  const { error } = await supabase.storage.from(imageBucket).remove([path])
  if (error) throw error
}

export async function cleanupOutletImageAssets(outletId: string): Promise<boolean> {
  if (!isR2Enabled()) return false
  if (!/^[0-9a-f-]{36}$/i.test(outletId)) throw new Error('Outlet tidak valid')
  // Cutover menjaga rollback: jangan hapus massal R2 maupun legacy Supabase
  // ketika outlet dihapus. Cleanup harus menjadi pekerjaan administratif yang
  // diaudit terpisah, bukan efek samping dari CRUD outlet.
  return true
}

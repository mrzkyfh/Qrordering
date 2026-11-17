import { createHash } from 'node:crypto'
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { basename, extname, join } from 'node:path'
import { spawnSync } from 'node:child_process'

const sourceManifestUrl = new URL('../migration-manifest.json', import.meta.url)
const outputManifestUrl = new URL('../optimized-manifest.json', import.meta.url)
const workerUrl = (process.env.ASSET_WORKER_URL ||
  'https://time420s-assets.timess402coffee.workers.dev').replace(/\/$/, '')
const bucket = process.env.R2_BUCKET || 'time420s-images'
const maxDimension = Number(process.env.IMAGE_MAX_DIMENSION || 720)
const quality = Number(process.env.IMAGE_WEBP_QUALITY || 78)

function command(name, args, cwd) {
  const result = spawnSync(name, args, {
    cwd,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
  })
  if (result.status !== 0) {
    throw new Error(`${name} gagal\n${result.stderr || result.stdout}`)
  }
  return result.stdout
}

function dimensions(file) {
  const output = command('sips', ['-g', 'pixelWidth', '-g', 'pixelHeight', file])
  const width = Number(output.match(/pixelWidth:\s*(\d+)/)?.[1])
  const height = Number(output.match(/pixelHeight:\s*(\d+)/)?.[1])
  if (!width || !height) throw new Error(`Dimensi gambar tidak terbaca: ${file}`)
  const scale = Math.min(1, maxDimension / Math.max(width, height))
  return {
    sourceWidth: width,
    sourceHeight: height,
    width: Math.max(1, Math.round(width * scale)),
    height: Math.max(1, Math.round(height * scale)),
  }
}

const manifest = JSON.parse(await readFile(sourceManifestUrl, 'utf8'))
const temp = await mkdtemp(join(tmpdir(), 'time420s-r2-optimize-'))
const optimized = []

try {
  for (let index = 0; index < manifest.length; index += 1) {
    const item = manifest[index]
    const sourceResponse = await fetch(item.target_url, { cache: 'no-store' })
    if (!sourceResponse.ok) {
      throw new Error(`${item.name}: sumber HTTP ${sourceResponse.status}`)
    }
    const extension = extname(new URL(item.target_url).pathname) || '.img'
    const sourceFile = join(temp, `${String(index).padStart(3, '0')}${extension}`)
    const targetFile = join(temp, `${String(index).padStart(3, '0')}.webp`)
    await writeFile(sourceFile, Buffer.from(await sourceResponse.arrayBuffer()))

    const size = dimensions(sourceFile)
    command('cwebp', [
      '-quiet', '-mt', '-m', '6', '-q', String(quality),
      '-resize', String(size.width), String(size.height),
      sourceFile, '-o', targetFile,
    ])

    const targetBytes = await readFile(targetFile)
    const oldName = basename(item.key, extname(item.key))
    const keyDirectory = item.key.slice(0, item.key.length - basename(item.key).length)
    const targetKey = `${keyDirectory.replace(/^menu\//, 'menu-thumbs/')}${oldName}.webp`
    command('npx', [
      'wrangler', 'r2', 'object', 'put', `${bucket}/${targetKey}`,
      '--file', targetFile, '--content-type', 'image/webp', '--remote',
    ], new URL('..', import.meta.url))

    const targetUrl = `${workerUrl}/assets/${targetKey}`
    const verify = await fetch(targetUrl, { cache: 'no-store' })
    if (!verify.ok || !verify.headers.get('content-type')?.startsWith('image/webp')) {
      throw new Error(`${item.name}: verifikasi thumbnail HTTP ${verify.status}`)
    }
    const verifiedBytes = Buffer.from(await verify.arrayBuffer())
    const expectedHash = createHash('sha256').update(targetBytes).digest('hex')
    const actualHash = createHash('sha256').update(verifiedBytes).digest('hex')
    if (expectedHash !== actualHash) throw new Error(`${item.name}: checksum berbeda`)

    optimized.push({
      id: item.id,
      outlet_id: item.outlet_id,
      name: item.name,
      source_url: item.target_url,
      target_url: targetUrl,
      key: targetKey,
      source_bytes: item.bytes,
      bytes: targetBytes.length,
      width: size.width,
      height: size.height,
      sha256: expectedHash,
    })
    process.stdout.write(
      `[${index + 1}/${manifest.length}] ${item.name}: ` +
      `${Math.round(item.bytes / 1024)}KB -> ${Math.round(targetBytes.length / 1024)}KB\n`,
    )
  }

  await writeFile(outputManifestUrl, `${JSON.stringify(optimized, null, 2)}\n`)
  const before = optimized.reduce((sum, item) => sum + item.source_bytes, 0)
  const after = optimized.reduce((sum, item) => sum + item.bytes, 0)
  process.stdout.write(
    `Selesai: ${optimized.length} gambar, ` +
    `${(before / 1024 / 1024).toFixed(2)}MB -> ${(after / 1024 / 1024).toFixed(2)}MB ` +
    `(-${((1 - after / before) * 100).toFixed(1)}%)\n`,
  )
} finally {
  await rm(temp, { recursive: true, force: true })
}

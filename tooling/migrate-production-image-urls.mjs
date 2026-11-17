import { createHash } from 'node:crypto'
import { execFile, spawn } from 'node:child_process'
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import os from 'node:os'
import path from 'node:path'
import { promisify } from 'node:util'

const execFileAsync = promisify(execFile)
const root = process.cwd()
const projectRef = 'yjmrabgpxjbunwtsiavs'
const accountId = '4e5b204f44bdff9f75eda4c3e99ee098'
const bucket = 'time420s-assets'
const publicBase = 'https://assets.time420s.my.id'
const supabaseBucket = 'menu-images'

function parseEnv(text) {
  return Object.fromEntries(text.split(/\r?\n/).map((line) => line.trim())
    .filter((line) => line && !line.startsWith('#') && line.includes('='))
    .map((line) => {
      const normalized = line.startsWith('export ') ? line.slice(7).trim() : line
      const at = normalized.indexOf('=')
      return [normalized.slice(0, at).trim(), normalized.slice(at + 1).trim().replace(/^(['"])(.*)\1$/, '$2')]
    }))
}

const sha256 = (value) => createHash('sha256').update(value).digest('hex')
const encoded = (value) => value.split('/').map(encodeURIComponent).join('/')

async function mapLimit(items, limit, fn) {
  const results = new Array(items.length)
  let cursor = 0
  async function worker() {
    while (cursor < items.length) {
      const index = cursor++
      results[index] = await fn(items[index], index)
    }
  }
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, worker))
  return results
}

async function fetchWithRetry(url, options = {}, attempts = 4) {
  let lastError
  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    try {
      return await fetch(url, options)
    } catch (error) {
      lastError = error
      if (attempt === attempts) throw error
      await new Promise((resolve) => setTimeout(resolve, attempt * 750))
    }
  }
  throw lastError
}

function runWrangler(args, env) {
  return new Promise((resolve, reject) => {
    const child = spawn('npx', ['wrangler', ...args], {
      cwd: path.join(root, 'apps/assets-worker'), env, stdio: ['ignore', 'ignore', 'pipe'],
    })
    let stderr = ''
    child.stderr.on('data', (value) => { stderr += value })
    child.on('close', (code) => code === 0 ? resolve() : reject(new Error(stderr.slice(-700))))
  })
}

async function getRows(owner, headers) {
  const select = 'id,name,outlet_id,image_url,updated_at,is_active,is_available,show_in_qr_menu'
  const response = await fetchWithRetry(`${owner.VITE_SUPABASE_URL}/rest/v1/menu_items?select=${select}&order=id.asc`, { headers })
  if (!response.ok) throw new Error(`menu_items audit HTTP ${response.status}`)
  return response.json()
}

function classify(url) {
  if (!url) return 'null'
  if (url.includes('.supabase.co/storage/v1/')) return 'supabase'
  if (url.startsWith(`${publicBase}/`)) return 'productionR2'
  if (url.includes('.r2.dev/') || url.includes('time420s-r2-staging')) return 'stagingR2'
  return 'other'
}

function sourcePathFromUrl(value) {
  const url = new URL(value)
  const marker = `/storage/v1/object/public/${supabaseBucket}/`
  if (!url.pathname.startsWith(marker)) return null
  const objectPath = decodeURIComponent(url.pathname.slice(marker.length))
  if (!objectPath || objectPath.split('/').some((part) => !part || part === '.' || part === '..')) return null
  return objectPath
}

async function loadServiceKey() {
  const { stdout } = await execFileAsync('supabase', ['projects', 'api-keys', '--project-ref', projectRef, '--output', 'json'], {
    cwd: root, maxBuffer: 2 * 1024 * 1024,
  })
  const starts = [stdout.indexOf('['), stdout.indexOf('{')].filter((index) => index >= 0)
  const keys = JSON.parse(stdout.slice(Math.min(...starts)))
  const entry = keys.find((item) => item.name === 'service_role' || item.name === 'secret')
  const key = entry?.api_key || entry?.key
  if (!key) throw new Error('Existing local Supabase CLI session cannot provide a privileged project key')
  return key
}

const owner = parseEnv(await readFile(path.join(root, 'apps/owner-panel/.env'), 'utf8'))
const cloudflare = parseEnv(await readFile(path.join(root, '.env.cloudflare-production'), 'utf8'))
if (!owner.VITE_SUPABASE_URL || !owner.VITE_SUPABASE_ANON_KEY || !cloudflare.CLOUDFLARE_API_TOKEN) {
  throw new Error('Required local configuration is unavailable')
}
const anonHeaders = { apikey: owner.VITE_SUPABASE_ANON_KEY, Authorization: `Bearer ${owner.VITE_SUPABASE_ANON_KEY}` }
const cfEnv = { ...process.env, CLOUDFLARE_API_TOKEN: cloudflare.CLOUDFLARE_API_TOKEN, CLOUDFLARE_ACCOUNT_ID: accountId }

const mode = process.argv[2]
if (mode === 'audit') {
  const runId = new Date().toISOString().replaceAll(':', '').replaceAll('-', '').replace(/\.\d{3}Z$/, 'Z')
  const outputDir = path.join(root, 'backups', `image-url-migration-${runId}`)
  const tempDir = await mkdtemp(path.join(os.tmpdir(), 'time420s-image-url-audit-'))
  await mkdir(outputDir, { recursive: true })
  try {
    const rows = await getRows(owner, anonHeaders)
    const backup = {
      generatedAt: new Date().toISOString(),
      rows: rows.map(({ id, name, outlet_id, image_url, updated_at }) => ({ id, name, outlet_id, image_url, updated_at })),
    }
    const backupText = `${JSON.stringify(backup, null, 2)}\n`
    const backupPath = path.join(outputDir, 'image-url-backup.json')
    await writeFile(backupPath, backupText, { mode: 0o600 })
    await writeFile(path.join(outputDir, 'image-url-backup.sha256'), `${sha256(backupText)}  image-url-backup.json\n`, { mode: 0o600 })

    const supabaseRows = rows.filter((row) => classify(row.image_url) === 'supabase')
    const invalidRows = []
    const byPath = new Map()
    for (const row of supabaseRows) {
      const objectPath = sourcePathFromUrl(row.image_url)
      if (!objectPath) { invalidRows.push({ id: row.id, image_url: row.image_url }); continue }
      if (!byPath.has(objectPath)) byPath.set(objectPath, [])
      byPath.get(objectPath).push(row)
    }
    const objects = [...byPath.entries()].map(([objectPath, references]) => ({ objectPath, references }))
    let completed = 0
    const audited = await mapLimit(objects, 6, async (object, index) => {
      const key = `${supabaseBucket}/${object.objectPath}`
      const sourceResponse = await fetchWithRetry(`${owner.VITE_SUPABASE_URL}/storage/v1/object/public/${supabaseBucket}/${encoded(object.objectPath)}`, { redirect: 'manual' })
      const sourceBytes = Buffer.from(await sourceResponse.arrayBuffer())
      const destinationFile = path.join(tempDir, `${index}.bin`)
      let destinationExists = true
      let destinationBytes = Buffer.alloc(0)
      try {
        await runWrangler(['r2', 'object', 'get', `${bucket}/${key}`, '--file', destinationFile, '--remote'], cfEnv)
        destinationBytes = await readFile(destinationFile)
      } catch { destinationExists = false }
      const publicResponse = await fetchWithRetry(`${publicBase}/${encoded(key)}`, { redirect: 'manual', headers: { 'Cache-Control': 'no-cache' } })
      const publicBytes = Buffer.from(await publicResponse.arrayBuffer())
      const sourceHash = sha256(sourceBytes)
      const destinationHash = destinationExists ? sha256(destinationBytes) : null
      const publicHash = sha256(publicBytes)
      completed++
      if (completed % 20 === 0 || completed === objects.length) console.log(`audit ${completed}/${objects.length}`)
      return {
        objectPath: object.objectPath, key, referenceCount: object.references.length,
        source: { status: sourceResponse.status, size: sourceBytes.length, sha256: sourceHash, contentType: sourceResponse.headers.get('content-type')?.split(';')[0] },
        destination: { exists: destinationExists, size: destinationBytes.length, sha256: destinationHash,
          matchesSource: destinationExists && destinationBytes.length === sourceBytes.length && destinationHash === sourceHash },
        public: { url: `${publicBase}/${encoded(key)}`, status: publicResponse.status, redirect: publicResponse.headers.get('location'),
          size: publicBytes.length, sha256: publicHash, contentType: publicResponse.headers.get('content-type')?.split(';')[0],
          matchesSource: publicResponse.status === 200 && !publicResponse.headers.get('location') && publicBytes.length === sourceBytes.length && publicHash === sourceHash },
      }
    })
    const auditByPath = new Map(audited.map((item) => [item.objectPath, item]))
    const plan = []
    const skipped = []
    for (const row of supabaseRows) {
      const objectPath = sourcePathFromUrl(row.image_url)
      const object = objectPath ? auditByPath.get(objectPath) : null
      const eligible = object && object.source.status === 200 && object.destination.matchesSource && object.public.matchesSource
      const target = object ? object.public.url : null
      const entry = { menu_item_id: row.id, name: row.name, outlet_id: row.outlet_id,
        old_supabase_url: row.image_url, new_production_r2_url: target, object_key: object?.key ?? null,
        source_checksum: object?.source.sha256 ?? null, destination_checksum: object?.destination.sha256 ?? null,
        audited_updated_at: row.updated_at, is_active: row.is_active, is_available: row.is_available,
        show_in_qr_menu: row.show_in_qr_menu }
      if (eligible) plan.push(entry)
      else skipped.push({ ...entry, reason: !object ? 'invalid_or_unrecognized_url' : !object.destination.exists ? 'missing_in_r2' : !object.destination.matchesSource ? 'checksum_or_size_mismatch' : 'public_read_failed' })
    }
    const canary = plan.find((row) => row.is_active && row.is_available && row.show_in_qr_menu) ?? plan[0] ?? null
    const distribution = rows.reduce((acc, row) => { acc[classify(row.image_url)]++; return acc }, { null: 0, supabase: 0, productionR2: 0, stagingR2: 0, other: 0 })
    const report = { generatedAt: new Date().toISOString(), outputDir, distribution,
      counts: { totalRows: rows.length, nonNull: rows.length - distribution.null, supabaseRows: supabaseRows.length,
        distinctSupabaseObjects: objects.length, eligibleRows: plan.length, skippedRows: skipped.length,
        missingObjects: audited.filter((x) => !x.destination.exists).length,
        checksumMismatches: audited.filter((x) => x.destination.exists && !x.destination.matchesSource).length,
        publicFailures: audited.filter((x) => !x.public.matchesSource).length,
        invalidUrls: invalidRows.length },
      canaryMenuItemId: canary?.menu_item_id ?? null, objects: audited, plan, skipped,
      backup: { path: backupPath, sha256: sha256(backupText) },
      rollbackMapping: plan.map((row) => ({ menu_item_id: row.menu_item_id, current_production_url: row.new_production_r2_url, rollback_supabase_url: row.old_supabase_url })),
      migration: { canary: null, batches: [], completed: false },
    }
    const reportPath = path.join(outputDir, 'migration-report.json')
    await writeFile(reportPath, `${JSON.stringify(report, null, 2)}\n`, { mode: 0o600 })
    console.log(JSON.stringify({ reportPath, distribution, counts: report.counts, canary: canary && { id: canary.menu_item_id, name: canary.name, outlet_id: canary.outlet_id }, backup: report.backup }, null, 2))
  } finally { await rm(tempDir, { recursive: true, force: true }) }
} else if (mode === 'canary' || mode === 'remaining') {
  const reportPath = path.resolve(process.argv[3] || '')
  if (!reportPath.startsWith(path.join(root, 'backups') + path.sep)) throw new Error('Report path guard failed')
  const report = JSON.parse(await readFile(reportPath, 'utf8'))
  const plan = report.plan
  if (!Array.isArray(plan) || !plan.length) throw new Error('Migration plan is empty')
  const ids = mode === 'canary'
    ? [report.canaryMenuItemId]
    : plan.filter((row) => row.menu_item_id !== report.canaryMenuItemId).map((row) => row.menu_item_id)
  if (mode === 'remaining' && !report.migration?.canary?.verified) throw new Error('Canary verification guard failed')
  const serviceKey = await loadServiceKey()
  const headers = { apikey: serviceKey, Authorization: `Bearer ${serviceKey}`, 'Content-Type': 'application/json', Prefer: 'return=representation' }
  const outcomes = []
  const batchSize = mode === 'canary' ? 1 : 10
  for (let offset = 0; offset < ids.length; offset += batchSize) {
    const batch = ids.slice(offset, offset + batchSize)
    const batchOutcomes = []
    for (const id of batch) {
      const item = plan.find((row) => row.menu_item_id === id)
      const url = `${owner.VITE_SUPABASE_URL}/rest/v1/menu_items?id=eq.${encodeURIComponent(id)}&image_url=eq.${encodeURIComponent(item.old_supabase_url)}&select=id,name,outlet_id,image_url,updated_at`
      const response = await fetch(url, { method: 'PATCH', headers, body: JSON.stringify({ image_url: item.new_production_r2_url }) })
      if (!response.ok) throw new Error(`Conditional update HTTP ${response.status} for ${id}`)
      const changed = await response.json()
      const outcome = changed.length === 1 && changed[0].image_url === item.new_production_r2_url
        ? { id, status: 'updated', before: item.old_supabase_url, after: changed[0].image_url, updated_at: changed[0].updated_at }
        : { id, status: 'concurrent_change_skipped', before: item.old_supabase_url, expectedAfter: item.new_production_r2_url }
      outcomes.push(outcome); batchOutcomes.push(outcome)
    }
    if (mode === 'remaining') report.migration.batches.push({ batch: report.migration.batches.length + 1, outcomes: batchOutcomes })
    await writeFile(reportPath, `${JSON.stringify(report, null, 2)}\n`, { mode: 0o600 })
    console.log(`${mode} batch ${Math.min(offset + batchSize, ids.length)}/${ids.length}`)
  }
  if (mode === 'canary') report.migration.canary = { outcome: outcomes[0], verified: false }
  else report.migration.remainingOutcomes = outcomes
  await writeFile(reportPath, `${JSON.stringify(report, null, 2)}\n`, { mode: 0o600 })
  console.log(JSON.stringify({ mode, outcomes }, null, 2))
} else if (mode === 'verify-canary' || mode === 'verify-customer' || mode === 'finalize') {
  const reportPath = path.resolve(process.argv[3] || '')
  if (!reportPath.startsWith(path.join(root, 'backups') + path.sep)) throw new Error('Report path guard failed')
  const report = JSON.parse(await readFile(reportPath, 'utf8'))
  const rows = await getRows(owner, anonHeaders)
  const distribution = rows.reduce((acc, row) => { acc[classify(row.image_url)]++; return acc }, { null: 0, supabase: 0, productionR2: 0, stagingR2: 0, other: 0 })
  if (mode === 'verify-canary') {
    const canary = report.plan.find((row) => row.menu_item_id === report.canaryMenuItemId)
    const current = rows.find((row) => row.id === canary.menu_item_id)
    const response = await fetchWithRetry(canary.new_production_r2_url, { redirect: 'manual', headers: { 'Cache-Control': 'no-cache' } })
    const bytes = Buffer.from(await response.arrayBuffer())
    const verified = current?.image_url === canary.new_production_r2_url && response.status === 200 && sha256(bytes) === canary.source_checksum
    report.migration.canary = { ...report.migration.canary, verified, databaseUrl: current?.image_url,
      publicStatus: response.status, publicChecksum: sha256(bytes), distributionAfterCanary: distribution }
    await writeFile(reportPath, `${JSON.stringify(report, null, 2)}\n`, { mode: 0o600 })
    console.log(JSON.stringify({ canary, verified, distribution }, null, 2))
    if (!verified) process.exitCode = 1
  } else if (mode === 'verify-customer') {
    const canary = report.plan.find((row) => row.menu_item_id === report.canaryMenuItemId)
    const serviceKey = await loadServiceKey()
    const serviceHeaders = { apikey: serviceKey, Authorization: `Bearer ${serviceKey}` }
    const tablesResponse = await fetchWithRetry(`${owner.VITE_SUPABASE_URL}/rest/v1/restaurant_tables?outlet_id=eq.${encodeURIComponent(canary.outlet_id)}&is_active=eq.true&qr_token=not.is.null&select=id,qr_token&limit=1`, { headers: serviceHeaders })
    if (!tablesResponse.ok) throw new Error(`Active table lookup HTTP ${tablesResponse.status}`)
    const [table] = await tablesResponse.json()
    if (!table?.qr_token) throw new Error('No active customer QR table is available for the canary outlet')
    const snapshotResponse = await fetchWithRetry(`${owner.VITE_SUPABASE_URL}/rest/v1/rpc/get_public_menu_snapshot`, {
      method: 'POST', headers: { ...anonHeaders, 'Content-Type': 'application/json' }, body: JSON.stringify({ p_token: table.qr_token }),
    })
    if (!snapshotResponse.ok) throw new Error(`Customer menu snapshot HTTP ${snapshotResponse.status}`)
    const snapshot = await snapshotResponse.json()
    const customerItem = (snapshot?.menu || []).find((item) => item.id === canary.menu_item_id)
    const imageResponse = customerItem?.image_url
      ? await fetchWithRetry(customerItem.image_url, { redirect: 'manual', headers: { 'Cache-Control': 'no-cache' } })
      : null
    const imageBytes = imageResponse ? Buffer.from(await imageResponse.arrayBuffer()) : Buffer.alloc(0)
    const verified = customerItem?.image_url === canary.new_production_r2_url
      && imageResponse?.status === 200 && sha256(imageBytes) === canary.source_checksum
    report.migration.customerCanary = { verified, tableId: table.id, tokenFingerprint: sha256(table.qr_token).slice(0, 12),
      snapshotMenuItemFound: Boolean(customerItem), imageUrl: customerItem?.image_url ?? null,
      publicStatus: imageResponse?.status ?? null, publicChecksum: imageResponse ? sha256(imageBytes) : null }
    await writeFile(reportPath, `${JSON.stringify(report, null, 2)}\n`, { mode: 0o600 })
    console.log(JSON.stringify(report.migration.customerCanary, null, 2))
    if (!verified) process.exitCode = 1
  } else {
    const planned = new Map(report.plan.map((item) => [item.menu_item_id, item]))
    const migrated = rows.filter((row) => planned.get(row.id)?.new_production_r2_url === row.image_url).map((row) => row.id)
    const unexpectedConcurrent = report.plan.filter((item) => {
      const row = rows.find((candidate) => candidate.id === item.menu_item_id)
      return row && row.image_url !== item.old_supabase_url && row.image_url !== item.new_production_r2_url
    }).map((item) => item.menu_item_id)
    report.migration.completed = migrated.length === report.plan.length && unexpectedConcurrent.length === 0
    report.migration.final = { distribution, migratedRows: migrated.length, skippedRows: report.skipped.length,
      remainingSupabase: distribution.supabase, remainingStaging: distribution.stagingR2,
      productionR2: distribution.productionR2, unexpectedConcurrent }
    await writeFile(reportPath, `${JSON.stringify(report, null, 2)}\n`, { mode: 0o600 })
    console.log(JSON.stringify(report.migration.final, null, 2))
  }
} else {
  throw new Error('Usage: audit | canary <report> | verify-canary <report> | verify-customer <report> | remaining <report> | finalize <report>')
}

import { execFile } from 'node:child_process'
import { readFile, writeFile } from 'node:fs/promises'
import path from 'node:path'
import { promisify } from 'node:util'

const execFileAsync = promisify(execFile)
const root = process.cwd()
const projectRef = 'yjmrabgpxjbunwtsiavs'
const promotionReportPath = path.join(root, 'backups/resolve-staging-images-20261012T054833Z/promotion-report.json')

function parseEnv(text) {
  return Object.fromEntries(text.split(/\r?\n/).map((line) => line.trim())
    .filter((line) => line && !line.startsWith('#') && line.includes('='))
    .map((line) => {
      const at = line.indexOf('=')
      return [line.slice(0, at).trim(), line.slice(at + 1).trim().replace(/^(['"])(.*)\1$/, '$2')]
    }))
}

const owner = parseEnv(await readFile(path.join(root, 'apps/owner-panel/.env'), 'utf8'))
const promotion = JSON.parse(await readFile(promotionReportPath, 'utf8'))
if (promotion.rows?.length !== 2 || promotion.rows.some((item) =>
  item.production.status !== 200 || !item.production.authenticatedMatch || !item.production.publicMatch)) {
  throw new Error('Promotion verification guard failed')
}

const { stdout } = await execFileAsync('supabase', ['projects', 'api-keys', '--project-ref', projectRef, '--output', 'json'], {
  cwd: root, maxBuffer: 2 * 1024 * 1024,
})
const jsonStart = Math.min(...['[', '{'].map((char) => stdout.indexOf(char)).filter((index) => index >= 0))
if (!Number.isFinite(jsonStart)) throw new Error('Could not read local Supabase project credentials')
const keys = JSON.parse(stdout.slice(jsonStart))
const serviceKeyEntry = keys.find((item) => item.name === 'service_role' || item.name === 'secret')
const serviceKey = serviceKeyEntry?.api_key || serviceKeyEntry?.key
if (!serviceKey) throw new Error('No privileged project key available through existing local Supabase CLI session')

const adminHeaders = { apikey: serviceKey, Authorization: `Bearer ${serviceKey}`, 'Content-Type': 'application/json' }
const anonHeaders = { apikey: owner.VITE_SUPABASE_ANON_KEY, Authorization: `Bearer ${owner.VITE_SUPABASE_ANON_KEY}` }
const ids = promotion.rows.map((item) => item.row.id)
const preflightUrl = `${owner.VITE_SUPABASE_URL}/rest/v1/menu_items?select=id,name,outlet_id,image_url,updated_at&id=in.(${ids.join(',')})`
const preflightResponse = await fetch(preflightUrl, { headers: anonHeaders })
if (!preflightResponse.ok) throw new Error(`Database preflight failed: HTTP ${preflightResponse.status}`)
const currentRows = await preflightResponse.json()
if (currentRows.length !== 2) throw new Error(`Database preflight expected 2 rows, found ${currentRows.length}`)
for (const item of promotion.rows) {
  const current = currentRows.find((row) => row.id === item.row.id)
  if (!current || current.image_url !== item.row.image_url) throw new Error(`Concurrent-change guard failed for ${item.row.id}`)
}

const changed = []
try {
  for (const item of promotion.rows) {
    const url = `${owner.VITE_SUPABASE_URL}/rest/v1/menu_items?id=eq.${encodeURIComponent(item.row.id)}&image_url=eq.${encodeURIComponent(item.row.image_url)}&select=id,name,outlet_id,image_url,updated_at`
    const response = await fetch(url, {
      method: 'PATCH', headers: { ...adminHeaders, Prefer: 'return=representation' },
      body: JSON.stringify({ image_url: item.production.url }),
    })
    if (!response.ok) throw new Error(`Update failed for ${item.row.id}: HTTP ${response.status}`)
    const returned = await response.json()
    if (returned.length !== 1 || returned[0].image_url !== item.production.url) {
      throw new Error(`Update guard failed for ${item.row.id}`)
    }
    changed.push({ before: item.row, after: returned[0], key: item.key })
  }
} catch (error) {
  for (const item of changed.reverse()) {
    await fetch(`${owner.VITE_SUPABASE_URL}/rest/v1/menu_items?id=eq.${encodeURIComponent(item.before.id)}&image_url=eq.${encodeURIComponent(item.after.image_url)}`, {
      method: 'PATCH', headers: adminHeaders, body: JSON.stringify({ image_url: item.before.image_url }),
    })
  }
  throw error
}

const auditResponse = await fetch(`${owner.VITE_SUPABASE_URL}/rest/v1/menu_items?select=id,image_url`, { headers: anonHeaders })
if (!auditResponse.ok) throw new Error(`Post-update audit failed: HTTP ${auditResponse.status}`)
const rows = await auditResponse.json()
const distribution = { total: rows.length, nonNull: 0, supabase: 0, productionR2: 0, stagingR2: 0, other: 0 }
for (const row of rows) {
  if (!row.image_url) continue
  distribution.nonNull++
  const value = String(row.image_url)
  if (value.includes('.supabase.co/storage/v1/')) distribution.supabase++
  else if (value.startsWith('https://assets.qrordering.my.id/')) distribution.productionR2++
  else if (value.includes('.r2.dev/') || value.includes('qrordering-r2-staging')) distribution.stagingR2++
  else distribution.other++
}
if (distribution.nonNull !== 114 || distribution.supabase !== 112 || distribution.productionR2 !== 2 || distribution.stagingR2 !== 0 || distribution.other !== 0) {
  throw new Error(`Post-update distribution guard failed: ${JSON.stringify(distribution)}`)
}

promotion.databaseUpdated = true
promotion.databaseChanges = changed
promotion.databaseDistributionAfter = distribution
await writeFile(promotionReportPath, `${JSON.stringify(promotion, null, 2)}\n`, { mode: 0o600 })
console.log(JSON.stringify({ databaseChanges: changed, databaseDistributionAfter: distribution }, null, 2))

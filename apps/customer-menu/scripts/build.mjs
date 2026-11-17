import { cp, mkdir, rm } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'
import path from 'node:path'

const projectDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const outputDir = path.join(projectDir, 'dist')
const assets = ['index.html', 'app.js', 'styles.css', 'logo.png', '_headers']
const vendorDir = path.join(outputDir, 'vendor')

await rm(outputDir, { recursive: true, force: true })
await mkdir(outputDir, { recursive: true })
await Promise.all(
  assets.map(asset => cp(path.join(projectDir, asset), path.join(outputDir, asset))),
)
await mkdir(vendorDir, { recursive: true })
await Promise.all([
  cp(
    path.join(projectDir, 'node_modules/@supabase/supabase-js/dist/umd/supabase.js'),
    path.join(vendorDir, 'supabase.js'),
  ),
  cp(
    path.join(projectDir, 'node_modules/@supabase/supabase-js/LICENSE'),
    path.join(vendorDir, 'SUPABASE-LICENSE'),
  ),
])

console.log(`Build menu pelanggan siap: ${assets.length} aset aplikasi dan pustaka Supabase lokal.`)

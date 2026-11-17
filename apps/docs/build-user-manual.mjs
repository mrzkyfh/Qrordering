import fs from 'node:fs/promises'
import path from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { chromium } from '../owner-panel/node_modules/playwright/index.mjs'

const docsDir = path.dirname(fileURLToPath(import.meta.url))
const markdownPath = path.join(docsDir, 'USER_MANUAL.md')
const cssPath = path.join(docsDir, 'user-manual.css')
const htmlPath = path.join(docsDir, 'USER_MANUAL.html')
const pdfPath = path.join(docsDir, 'USER_MANUAL.pdf')

const [markdown, css] = await Promise.all([
  fs.readFile(markdownPath, 'utf8'),
  fs.readFile(cssPath, 'utf8'),
])

const escapeHtml = (value) => value
  .replaceAll('&', '&amp;')
  .replaceAll('<', '&lt;')
  .replaceAll('>', '&gt;')
  .replaceAll('"', '&quot;')

const inline = (value) => {
  const code = []
  let result = escapeHtml(value).replace(/`([^`]+)`/g, (_, content) => {
    const token = `%%CODE_${code.length}%%`
    code.push(`<code>${content}</code>`)
    return token
  })
  result = result
    .replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>')
    .replace(/\*([^*]+)\*/g, '<em>$1</em>')
    .replace(/\[([^\]]+)\]\(([^)]+)\)/g, '<a href="$2">$1</a>')
  code.forEach((content, index) => {
    result = result.replace(`%%CODE_${index}%%`, content)
  })
  return result
}

const slugCounts = new Map()
const slugify = (value) => {
  const base = value
    .toLowerCase()
    .replace(/<[^>]+>/g, '')
    .replace(/[^\p{L}\p{N}]+/gu, '-')
    .replace(/^-|-$/g, '') || 'bagian'
  const count = slugCounts.get(base) ?? 0
  slugCounts.set(base, count + 1)
  return count === 0 ? base : `${base}-${count + 1}`
}

const sourceLines = markdown.split(/\r?\n/)
const headings = []
for (const line of sourceLines) {
  const match = /^(#{1,2})\s+(.+)$/.exec(line)
  if (match) headings.push({
    level: match[1].length,
    text: match[2],
    id: slugify(match[2]),
  })
}

slugCounts.clear()

const toc = `<nav class="toc">${headings
  .filter((heading) => (
    heading.level === 1
    && heading.text !== 'Daftar isi'
    && heading.text !== 'Tentang modul ini'
  ))
  .map((heading) => (
    `<a class="level-${heading.level}" href="#${heading.id}">${inline(heading.text)}</a>`
  ))
  .join('')}</nav>`

const isSpecial = (line, next = '') => (
  line.trim() === ''
  || /^#{1,6}\s+/.test(line)
  || line.trim() === '[TOC]'
  || line.trim() === '---'
  || line.startsWith('```')
  || line.startsWith('>')
  || /^[-*]\s+/.test(line)
  || /^\d+\.\s+/.test(line)
  || (line.trim().startsWith('|') && next.trim().startsWith('|'))
  || /^<(section|div)\b/.test(line.trim())
)

const output = []
let index = 0
while (index < sourceLines.length) {
  const line = sourceLines[index]
  const trimmed = line.trim()
  const next = sourceLines[index + 1] ?? ''

  if (!trimmed) {
    index += 1
    continue
  }

  if (/^<(section|div)\b/.test(trimmed)) {
    const tag = trimmed.startsWith('<section') ? 'section' : 'div'
    const block = [line]
    index += 1
    if (line.includes(`</${tag}>`)) {
      output.push(block.join('\n'))
      continue
    }
    while (index < sourceLines.length) {
      block.push(sourceLines[index])
      if (sourceLines[index].includes(`</${tag}>`)) {
        index += 1
        break
      }
      index += 1
    }
    output.push(block.join('\n'))
    continue
  }

  if (trimmed === '[TOC]') {
    output.push(toc)
    index += 1
    continue
  }

  const heading = /^(#{1,6})\s+(.+)$/.exec(line)
  if (heading) {
    const level = heading[1].length
    const id = slugify(heading[2])
    output.push(`<h${level} id="${id}">${inline(heading[2])}</h${level}>`)
    index += 1
    continue
  }

  if (trimmed === '---') {
    output.push('<hr>')
    index += 1
    continue
  }

  if (line.startsWith('```')) {
    const language = line.slice(3).trim()
    const block = []
    index += 1
    while (index < sourceLines.length && !sourceLines[index].startsWith('```')) {
      block.push(sourceLines[index])
      index += 1
    }
    index += 1
    output.push(`<pre><code class="language-${escapeHtml(language)}">${escapeHtml(block.join('\n'))}</code></pre>`)
    continue
  }

  if (line.startsWith('>')) {
    const block = []
    while (index < sourceLines.length && sourceLines[index].startsWith('>')) {
      block.push(sourceLines[index].replace(/^>\s?/, ''))
      index += 1
    }
    output.push(`<blockquote><p>${inline(block.join(' '))}</p></blockquote>`)
    continue
  }

  if (trimmed.startsWith('|') && next.trim().startsWith('|')) {
    const rows = []
    while (index < sourceLines.length && sourceLines[index].trim().startsWith('|')) {
      rows.push(sourceLines[index].trim())
      index += 1
    }
    const cells = rows.map((row) => row.slice(1, -1).split('|').map((cell) => cell.trim()))
    const headers = cells[0]
    const body = cells.slice(2)
    output.push(
      `<table><thead><tr>${headers.map((cell) => `<th>${inline(cell)}</th>`).join('')}</tr></thead>`
      + `<tbody>${body.map((row) => `<tr>${row.map((cell) => `<td>${inline(cell)}</td>`).join('')}</tr>`).join('')}</tbody></table>`,
    )
    continue
  }

  const unordered = /^[-*]\s+/.test(line)
  const ordered = /^\d+\.\s+/.test(line)
  if (unordered || ordered) {
    const listClass = unordered ? 'unordered' : 'ordered'
    const pattern = unordered ? /^[-*]\s+/ : /^\d+\.\s+/
    const items = []
    while (index < sourceLines.length && pattern.test(sourceLines[index])) {
      let item = sourceLines[index].replace(pattern, '')
      item = item.replace(/^\[ \]\s*/, '<span class="checkbox"></span>')
      item = item.replace(/^\[[xX]\]\s*/, '<span class="checkbox checked">✓</span>')
      const checkClass = item.includes('checkbox') ? ' check-item' : ''
      const itemContent = item.includes('checkbox') ? item : inline(item)
      items.push(`<div class="list-item${checkClass}"><div class="list-content">${itemContent}</div></div>`)
      index += 1
    }
    output.push(`<div class="list ${listClass}">${items.join('')}</div>`)
    continue
  }

  const paragraph = [line.trim()]
  index += 1
  while (
    index < sourceLines.length
    && !isSpecial(sourceLines[index], sourceLines[index + 1] ?? '')
  ) {
    paragraph.push(sourceLines[index].trim())
    index += 1
  }
  const paragraphText = paragraph.join(' ')
  if (/^Lokasi(?:\s|:)/.test(paragraphText)) {
    output.push(`<div class="location">${inline(paragraphText.replace(/^Lokasi(?:\s*:\s*|\s+)/, ''))}</div>`)
  } else {
    output.push(`<p>${inline(paragraphText)}</p>`)
  }
}

const html = `<!doctype html>
<html lang="id">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Modul Penggunaan Time420s</title>
  <style>${css}</style>
</head>
<body>${output.join('\n')}</body>
</html>`

await fs.writeFile(htmlPath, html)

const browser = await chromium.launch({ headless: true })
try {
  const page = await browser.newPage()
  await page.goto(pathToFileURL(htmlPath).href, { waitUntil: 'networkidle' })
  await page.emulateMedia({ media: 'print' })
  await page.pdf({
    path: pdfPath,
    format: 'A4',
    printBackground: true,
    displayHeaderFooter: true,
    margin: {
      top: '18mm',
      right: '15mm',
      bottom: '19mm',
      left: '15mm',
    },
    headerTemplate: '<div></div>',
    footerTemplate: `
      <div style="box-sizing:border-box;width:100%;margin:0 15mm;padding-top:2mm;border-top:1px solid #e5e7eb;font:8px Arial;color:#8a94a3;display:flex;justify-content:space-between;">
        <span>Time420s · Modul Penggunaan</span>
        <span>Halaman <span class="pageNumber"></span> dari <span class="totalPages"></span></span>
      </div>`,
  })
} finally {
  await browser.close()
}

const stats = await fs.stat(pdfPath)
console.log(`PDF dibuat: ${pdfPath}`)
console.log(`Ukuran: ${(stats.size / 1024 / 1024).toFixed(2)} MB`)

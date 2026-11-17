// Shared report export utility — Excel, CSV, PDF

import { format } from 'date-fns'
import { id as localeId } from 'date-fns/locale'

export interface ReportConfig {
  title: string
  outletName: string
  period: string
  periodView?: string
  summaryStats: Array<{ label: string; value: string }>
  tableHeaders: string[]
  tableRows: (string | number)[][]
  filename: string
}


function esc(s: string): string {
  return s
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&#39;')
}

function sanitizeCSVCell(s: string): string {
  if (s && ['+', '-', '=', '@', '\t', '\r'].some((c) => s.startsWith(c))) return `'${s}`
  return s
}

function trigger(blob: Blob, filename: string) {
  const url = URL.createObjectURL(blob)
  const a = document.createElement('a')
  a.href = url; a.download = filename
  document.body.appendChild(a); a.click()
  document.body.removeChild(a); URL.revokeObjectURL(url)
}

// ── Excel ─────────────────────────────────────────────────────────────────────

// Estimate a reasonable column width in px from the header label
function colPx(header: string): number {
  const map: Record<string, number> = {
    'no transaksi': 150, 'waktu order': 130, 'waktu bayar': 130,
    'jenis order': 90, 'total (rp)': 100, 'pembayaran': 90,
    'bayar': 90, 'order': 90, 'tanggal': 120, 'transaksi': 80,
    'departemen': 130, 'kategori': 120, 'menu': 160, 'qty terjual': 80,
    'revenue': 120, 'total orders': 90, 'service charge (rp)': 140,
    'net revenue (rp)': 130, 'total penjualan (rp)': 140,
    'pajak (rp)': 110, 'extra': 130, 'tipe': 80, 'seleksi': 80, 'aktif': 60,
  }
  const key = header.toLowerCase()
  for (const [k, v] of Object.entries(map)) {
    if (key.includes(k)) return v
  }
  return Math.max(80, header.length * 7 + 16)
}

export function exportReportExcel(cfg: ReportConfig): void {
  const generatedAt = format(new Date(), 'd MMMM yyyy - HH:mm', { locale: localeId }) + ' WIB'

  // Only Periode (no Zona Waktu, no Semua Outlet)
  const leftMeta = [
    ['Periode', cfg.period],
    ...(cfg.periodView ? [['Periode View', cfg.periodView]] : []),
  ]
  const stats    = cfg.summaryStats
  const metaRows = Math.max(leftMeta.length, stats.length)

  const TD = `font-size:9pt;vertical-align:middle;`

  // ── TABLE 1: title + meta ─────────────────────────────────────────────────

  let metaHtml = ''
  for (let i = 0; i < metaRows; i++) {
    const l = leftMeta[i]
    const r = stats[i]
    metaHtml += `<tr>
      <td style="${TD}color:#888;padding:3px 12px;width:90px;">${l ? esc(l[0]) : ''}</td>
      <td style="${TD}color:#333;font-weight:${l ? 'bold' : 'normal'};padding:3px 12px;min-width:200px;">${l ? esc(l[1]) : ''}</td>
      <td style="width:60px;"></td>
      <td style="${TD}color:#888;padding:3px 12px;width:150px;">${r ? esc(r.label) : ''}</td>
      <td style="${TD}color:#111;font-weight:bold;text-align:right;padding:3px 12px;min-width:140px;">${r ? esc(r.value) : ''}</td>
    </tr>`
  }

  const table1 = `<table style="border-collapse:collapse;margin-bottom:8px;width:100%;">
    <tr style="height:36px;">
      <td colspan="2" style="${TD}font-size:18pt;font-weight:bold;color:#111;padding:8px 12px;">${esc(cfg.title)}</td>
      <td style=""></td>
      <td colspan="2" style="${TD}font-size:11pt;font-weight:bold;color:#222;text-align:right;padding:8px 12px;">${esc(cfg.outletName)}</td>
    </tr>
    <tr><td colspan="5" style="height:2px;background:#E3E3E3;padding:0;"></td></tr>
    <tr><td colspan="5" style="height:8px;"></td></tr>
    ${metaHtml}
    <tr><td colspan="5" style="height:8px;"></td></tr>
    <tr>
      <td colspan="5" style="${TD}color:#aaa;font-size:8pt;text-align:right;padding:3px 12px;font-style:italic;">
        Date Generated: ${esc(generatedAt)}
      </td>
    </tr>
    <tr><td colspan="5" style="height:12px;"></td></tr>
  </table>`

  // ── TABLE 2: data with explicit column widths ─────────────────────────────
  // Warna mengikuti tema aplikasi (--primary: 356 77% 50%).
  const TH_BG  = '#E21D2A'
  const widths = cfg.tableHeaders.map((h) => colPx(h))

  const colgroup = `<colgroup>${widths.map((w) => `<col style="width:${w}px;min-width:${w}px;" />`).join('')}</colgroup>`

  const headerRow = `<tr style="height:28px;">${cfg.tableHeaders.map((h, i) =>
    `<th style="background:${TH_BG};color:#fff;font-weight:bold;padding:5px 10px;text-align:${i === 0 ? 'left' : 'right'};font-size:9pt;white-space:nowrap;vertical-align:middle;border:none;">${esc(h)}</th>`
  ).join('')}</tr>`

  const dataRows = cfg.tableRows.map((row, ri) => {
    const bg = ri % 2 === 0 ? '#ffffff' : '#FCE8EA'
    const cells = row.map((cell, ci) =>
      `<td style="${TD}background:${bg};padding:4px 10px;border-bottom:1px solid #E3E3E3;text-align:${ci === 0 ? 'left' : 'right'};white-space:nowrap;">${esc(String(cell ?? ''))}</td>`
    ).join('')
    return `<tr style="height:22px;">${cells}</tr>`
  }).join('')

  const table2 = `<table style="border-collapse:collapse;">
    ${colgroup}
    ${headerRow}
    ${dataRows}
    <tr><td colspan="${cfg.tableHeaders.length}" style="height:8px;"></td></tr>
  </table>`

  const html = `<html xmlns:o="urn:schemas-microsoft-com:office:office" xmlns:x="urn:schemas-microsoft-com:office:excel" xmlns="http://www.w3.org/TR/REC-html40">
<head><meta charset="utf-8"><title>${esc(cfg.title)}</title>
<style>
  body { font-family: Calibri, Arial, sans-serif; }
</style>
</head>
<body>
${table1}
${table2}
</body>
</html>`

  trigger(new Blob(['﻿' + html], { type: 'application/vnd.ms-excel;charset=utf-8' }), cfg.filename)
}

// ── CSV ──────────────────────────────────────────────────────────────────────

export function exportReportCSV(cfg: ReportConfig): void {
  const generatedAt = format(new Date(), 'd MMMM yyyy HH:mm', { locale: localeId }) + ' WIB'
  const cols = cfg.tableHeaders.length
  const empty = (n: number) => Array(n).fill('').join(',')

  const leftMeta = [
    ['Periode', cfg.period],
    ...(cfg.periodView ? [['Periode View', cfg.periodView]] : []),
  ]
  const metaRows = Math.max(leftMeta.length, cfg.summaryStats.length)

  const csvCell = (s: string) => {
    const c = sanitizeCSVCell(s)
    return c.includes(',') || c.includes('"') || c.includes('\n') ? `"${c.replace(/"/g, '""')}"` : c
  }

  const lines: string[] = []
  lines.push(`"${cfg.title}"${empty(Math.max(0, cols - 2))},"${cfg.outletName}"`)
  lines.push(empty(cols))

  const half = Math.floor(cols / 2)
  for (let i = 0; i < metaRows; i++) {
    const l = leftMeta[i]
    const r = cfg.summaryStats[i]
    const lStr = l ? `"${l[0]}","${l[1]}"` : ','
    const gap  = empty(Math.max(0, half - 2))
    const rStr = r ? `"${r.label}","${r.value}"` : ','
    lines.push([lStr, gap, rStr].filter(Boolean).join(','))
  }

  lines.push(empty(cols))
  lines.push(`${empty(cols - 1)},"Date Generated: ${generatedAt}"`)
  lines.push(empty(cols))
  lines.push(cfg.tableHeaders.map((h) => `"${h}"`).join(','))
  for (const row of cfg.tableRows) {
    lines.push(row.map((cell) => csvCell(String(cell ?? ''))).join(','))
  }

  trigger(new Blob(['﻿' + lines.join('\r\n')], { type: 'text/csv;charset=utf-8;' }), cfg.filename)
}

// ── PDF ───────────────────────────────────────────────────────────────────────

export async function exportReportPDF(cfg: ReportConfig): Promise<void> {
  const [{ default: jsPDF }, { default: autoTable }] = await Promise.all([
    import('jspdf'),
    import('jspdf-autotable'),
  ])

  const doc  = new jsPDF({ orientation: 'portrait' })
  const pageW = doc.internal.pageSize.getWidth()
  const pageH = doc.internal.pageSize.getHeight()
  const generatedAt = format(new Date(), 'd MMMM yyyy HH:mm', { locale: localeId }) + ' WIB'

  let y = 16

  // Title (left) + outlet name (right)
  doc.setFontSize(18); doc.setFont('helvetica', 'bold'); doc.setTextColor(20, 20, 20)
  doc.text(cfg.title, 14, y)
  doc.setFontSize(11); doc.setFont('helvetica', 'bold'); doc.setTextColor(40, 40, 40)
  doc.text(cfg.outletName, pageW - 14, y, { align: 'right' })
  y += 6

  // Thin divider (warna border tema aplikasi)
  doc.setDrawColor(227, 227, 227); doc.setLineWidth(0.3)
  doc.line(14, y, pageW - 14, y); y += 7

  // Meta (Periode only) left + stats right
  const leftMeta = [
    ['Periode', cfg.period],
    ...(cfg.periodView ? [['Periode View', cfg.periodView]] : []),
  ]
  const metaRows = Math.max(leftMeta.length, cfg.summaryStats.length)
  const midX = pageW / 2 + 4

  doc.setFontSize(8.5)
  for (let i = 0; i < metaRows; i++) {
    const l = leftMeta[i]
    const r = cfg.summaryStats[i]
    if (l) {
      doc.setFont('helvetica', 'normal'); doc.setTextColor(150, 150, 150)
      doc.text(l[0], 14, y)
      doc.setFont('helvetica', 'bold'); doc.setTextColor(40, 40, 40)
      doc.text(l[1], 46, y)
    }
    if (r) {
      doc.setFont('helvetica', 'normal'); doc.setTextColor(150, 150, 150)
      doc.text(r.label, midX, y)
      doc.setFont('helvetica', 'bold'); doc.setTextColor(30, 30, 30)
      doc.text(r.value, pageW - 14, y, { align: 'right' })
    }
    y += 6
  }

  // Date generated
  y += 3
  doc.setFontSize(7.5); doc.setFont('helvetica', 'italic'); doc.setTextColor(180, 180, 180)
  doc.text(`Date Generated: ${generatedAt}`, pageW - 14, y, { align: 'right' })
  y += 8

  // Table
  autoTable(doc, {
    head: [cfg.tableHeaders],
    body: cfg.tableRows,
    startY: y,
    theme: 'striped',
    // Warna mengikuti tema aplikasi (--primary: 356 77% 50% = #E21D2A).
    headStyles: { fillColor: [226, 29, 42], textColor: [255, 255, 255], fontStyle: 'bold', fontSize: 9, halign: 'right' },
    columnStyles: { 0: { halign: 'left' } },
    bodyStyles: { fontSize: 8, textColor: [40, 40, 40], halign: 'right' },
    alternateRowStyles: { fillColor: [252, 232, 234] },
    margin: { left: 14, right: 14 },
  })

  // Footer
  const pages = (doc as unknown as { internal: { getNumberOfPages(): number } }).internal.getNumberOfPages()
  for (let i = 1; i <= pages; i++) {
    doc.setPage(i)
    doc.setFontSize(7.5); doc.setFont('helvetica', 'normal'); doc.setTextColor(180, 180, 180)
    doc.text(
      `Halaman ${i} dari ${pages}  |  Dicetak ${format(new Date(), 'd MMM yyyy HH:mm', { locale: localeId })}`,
      pageW / 2, pageH - 8, { align: 'center' },
    )
  }

  doc.save(cfg.filename)
}

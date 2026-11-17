import fs from 'node:fs'
import path from 'node:path'
import ts from 'typescript'

const sourceRoot = path.resolve('src')
const files = []

function collectFiles(directory) {
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    const target = path.join(directory, entry.name)
    if (entry.isDirectory()) collectFiles(target)
    else if (target.endsWith('.tsx')) files.push(target)
  }
}

function tagName(node) {
  return node.tagName.getText()
}

function attributes(node) {
  const result = {}
  for (const property of node.attributes.properties) {
    if (ts.isJsxAttribute(property)) {
      result[property.name.text] = property.initializer?.getText() ?? 'true'
    }
  }
  return result
}

function ancestorTags(node) {
  const result = []
  for (let parent = node.parent; parent; parent = parent.parent) {
    if (ts.isJsxElement(parent)) result.push(tagName(parent.openingElement))
  }
  return result
}

function isTriggerAttributeChild(node) {
  for (let parent = node.parent; parent; parent = parent.parent) {
    if (ts.isJsxAttribute(parent) && parent.name.text === 'trigger') return true
  }
  return false
}

collectFiles(sourceRoot)

let total = 0
let standard = 0
let custom = 0
let actionEquivalent = 0
const violations = []

for (const file of files) {
  const sourceFile = ts.createSourceFile(
    file,
    fs.readFileSync(file, 'utf8'),
    ts.ScriptTarget.Latest,
    true,
    ts.ScriptKind.TSX,
  )

  function report(node, message) {
    const { line } = sourceFile.getLineAndCharacterOfPosition(node.getStart())
    violations.push(`${path.relative(process.cwd(), file)}:${line + 1} — ${message}`)
  }

  function visit(node) {
    if (ts.isJsxElement(node)) {
      const opening = node.openingElement
      const tag = tagName(opening)
      const attrs = attributes(opening)
      const ancestors = ancestorTags(node)

      if (tag === 'Button' || tag === 'button') {
        total += 1
        if (tag === 'Button') standard += 1
        else custom += 1

        if (tag === 'button' && !attrs.type) {
          report(opening, 'tombol native wajib memiliki type eksplisit')
        }
        if (ancestors.includes('form') && !attrs.type) {
          report(opening, 'tombol di dalam form wajib menyatakan type')
        }
        if (/icon/.test(attrs.size ?? '') && !attrs['aria-label'] && !attrs.title) {
          report(opening, 'tombol ikon wajib memiliki aria-label')
        }
        if (
          attrs.size === '"icon"'
          && /(?:h|w)-(?:7|8|9)\b/.test(attrs.className ?? '')
        ) {
          report(opening, 'gunakan size icon-sm/icon-xs, bukan override tinggi/lebar')
        }

        const isTrigger = ancestors.some((name) => name.endsWith('Trigger'))
        const isConfirmTrigger =
          ancestors.includes('ConfirmDialog')
          || isTriggerAttributeChild(node)
        const hasAction =
          Boolean(attrs.onClick)
          || attrs.type === '"submit"'
          || Boolean(attrs.asChild)
          || isTrigger
          || isConfirmTrigger
        if (!hasAction) report(opening, 'tombol tidak memiliki aksi atau trigger')
      }

      if (['AlertDialogAction', 'DropdownMenuItem', 'TabsTrigger'].includes(tag)) {
        actionEquivalent += 1
        const hasAction =
          Boolean(attrs.onClick)
          || Boolean(attrs.onSelect)
          || Boolean(attrs.value)
        if (!hasAction) report(opening, `${tag} tidak memiliki aksi/value`)
      }
    }
    node.forEachChild(visit)
  }

  visit(sourceFile)
}

console.log(
  `Button audit: ${total} tombol (${standard} standar, ${custom} custom) `
  + `+ ${actionEquivalent} kontrol setara tombol.`,
)

if (violations.length > 0) {
  console.error(violations.join('\n'))
  process.exitCode = 1
} else {
  console.log('Lulus: tidak ada pelanggaran kontrak tombol statis.')
}

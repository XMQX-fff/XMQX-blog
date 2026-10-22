// 构建前校验：把 docs/ 下所有 ```mermaid 代码块喂给 mermaid 的解析器。
//
// 为什么需要：mermaid 的图是在浏览器里运行时渲染的，源码写错时构建不报错、
// 页面却会显示一张 "Syntax error in text" 的报错图。把错误拦在构建期，
// 比上线后再翻页面便宜得多。
//
// 用法：node deploy/check-mermaid.mjs [docs 目录]
import fs from 'node:fs'
import path from 'node:path'
import process from 'node:process'
import { register } from 'node:module'

// mermaid 的解析路径会调用 DOMPurify.sanitize，而 Node 里没有 DOM，
// dompurify 导出的只是工厂函数（没有 .addHook）。这里把 dompurify 换成一个
// 只做「原样返回」的桩：校验的是语法，HTML 转义那一层与此无关。
register('./mermaid-dom-loader.mjs', import.meta.url)

const root = path.resolve(process.argv[2] ?? 'docs')

function walk(dir, out = []) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (entry.name === 'node_modules' || entry.name === '.vitepress' || entry.name === 'dist') {
      continue
    }
    const full = path.join(dir, entry.name)
    if (entry.isDirectory()) walk(full, out)
    else if (entry.name.endsWith('.md')) out.push(full)
  }
  return out
}

const blocks = []
for (const file of walk(root)) {
  const text = fs.readFileSync(file, 'utf8')
  const rx = /```mermaid[^\S\n]*\n([\s\S]*?)```/g
  let m
  while ((m = rx.exec(text)) !== null) {
    blocks.push({
      file: path.relative(process.cwd(), file),
      line: text.slice(0, m.index).split('\n').length,
      code: m[1],
    })
  }
}

if (blocks.length === 0) {
  console.log('没有 mermaid 图，跳过')
  process.exit(0)
}

let mermaid
try {
  mermaid = (await import('mermaid')).default
} catch (err) {
  console.error('无法加载 mermaid，跳过校验：', err.message)
  process.exit(0)
}

mermaid.initialize({ startOnLoad: false, securityLevel: 'loose' })

let failed = 0
for (const b of blocks) {
  try {
    await mermaid.parse(b.code)
  } catch (err) {
    failed++
    const msg = String(err?.message ?? err).split('\n').slice(0, 6).join('\n')
    console.error(`\n✗ ${b.file}:${b.line}\n${msg}\n---- 源码 ----\n${b.code}`)
  }
}

if (failed) {
  console.error(`\n${failed} 个 mermaid 图语法有误，构建中止。`)
  process.exit(1)
}
console.log(`${blocks.length} 个 mermaid 图语法全部通过`)

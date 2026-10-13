// 从内联 HTML 里抽标题，喂给 VitePress 的右侧「本页目录」。
//
// 为什么需要：VitePress 的 headers 由 @mdit-vue/plugin-headers 从 markdown 的
// 标题 token（`## xxx`）里收集。GraphRAG 那两页是「一整块不间断的内联 HTML」
// （html2vp.py 的转换结果），标题全是 <h2>/<h3> 标签，markdown-it 看不见，
// 于是 page.data.headers 是空数组，右侧目录什么都不显示。
//
// 这里在 VitePress 自己的 headers 插件之后再包一层 render：从 env.path 读回
// 源文件，按文档顺序扫出 <h1>~<h4>，用 html2vp.py 注入的 id 当锚点。
//
// id 的来源是转换器：优先沿用 <section id="l1"> 这类祖先元素的 id（这样原来
// 手写目录里的 #l1 / #s4-1 链接继续有效），没有才按标题文本生成。
import fs from 'node:fs'
import path from 'node:path'

const HEADING_RX = /<(h[1-4])([^>]*)>([\s\S]*?)<\/\1>/g
const ID_RX = /\bid=["']([^"']+)["']/

/** 默认取 outline 配置里的层级；没配就是 h2/h3。 */
function levelsOf(siteConfig) {
  const levels = siteConfig?.themeConfig?.outline?.level
  return Array.isArray(levels) ? levels : [2, 3]
}

export function htmlHeadingsPlugin(md, siteConfig = {}) {
  const levels = levelsOf(siteConfig)
  const wanted = new Set(levels.map(String))
  const render = md.renderer.render.bind(md.renderer)

  md.renderer.render = (tokens, options, env) => {
    // 先调原 render 并把结果返回去。VitePress 的本地搜索插件会 await
    // markdownToHtml 的返回值拿页面 HTML；不 return 的话它拿到 undefined，
    // 下一行 .split() 直接抛 "Cannot read properties of undefined"。
    const html = render(tokens, options, env)

    // VitePress 自己的 headers 插件已经写好了 env.headers；这里只在它是空的
    // 时候补，绝不覆盖 markdown 标题的结果。
    if (env?.headers?.length || !env?.path) return html

    let raw
    try {
      const root = path.resolve(process.cwd(), 'docs')
      const file = path.resolve(root, env.path)
      if (!file.startsWith(root + path.sep)) return  // 防目录穿越
      raw = fs.readFileSync(file, 'utf-8')
    } catch {
      return html
    }

    const headers = []
    const seen = new Set()
    let m
    HEADING_RX.lastIndex = 0
    while ((m = HEADING_RX.exec(raw)) !== null) {
      const level = Number(m[1][1])
      if (!wanted.has(String(level))) continue
      const id = ID_RX.exec(m[2])?.[1]
      if (!id || seen.has(id)) continue
      seen.add(id)
      headers.push({
        level,
        title: m[3].replace(/<[^>]+>/g, '').trim(),
        slug: id,
      })
    }
    if (headers.length) env.headers = headers
    return html
  }
}
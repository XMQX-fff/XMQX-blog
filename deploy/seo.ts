// SEO 公共逻辑：页面 URL 规范化、描述自动生成、每页 head 标签与结构化数据。
//
// 抽成独立模块的原因：config.mts 里要同时挂 transformHead（每页 head）和
// transformPageData（描述），两处都依赖「页面文件路径 → 站点 URL」和
// 「markdown 源码 → 一句话描述」这两个换算。放在一起便于单独跑脚本核对，
// config.mts 也能保持一眼看得懂。

import type { HeadConfig } from 'vitepress'

/** 站点主域名。规范链接、sitemap、社交卡片都指向这里。 */
export const SITE_URL = 'https://xmqx.online'

/** 站点名，出现在 og:site_name、JSON-LD 的 publisher 里。 */
export const SITE_NAME = 'XMQX 的博客'

/** 社交分享封面，1200x630。 */
export const OG_IMAGE = `${SITE_URL}/og.png`

/** 各栏目目录对应的中文名，用于面包屑和 articleSection。 */
export const COLUMN_NAMES: Record<string, string> = {
  graphrag: 'GraphRAG 学习',
  langgraph: 'LangGraph 学习',
  langchain: 'LangChain 学习',
  a2a: 'A2A 协议学习',
  agentnovel: 'AgentNovel 设计文档',
}

/**
 * 页面文件相对路径 → 站点内的 URL 路径。
 *
 *   index.md                  → /
 *   graphrag/index.md         → /graphrag/
 *   graphrag/why-graphrag.md  → /graphrag/why-graphrag
 *
 * 站点开了 cleanUrls，产物里仍然是 .html 文件，由 nginx 的
 * `try_files $uri $uri/ $uri.html` 兜住无扩展名的请求。
 */
export function urlPathOf(page: string): string {
  let p = '/' + page.replace(/\\/g, '/').replace(/^\/+/, '')
  p = p.replace(/\.md$/, '')
  p = p.replace(/\/index$/, '/')
  return p
}

/** 页面文件相对路径 → 站点内的绝对 URL。 */
export function absoluteUrlOf(page: string): string {
  return SITE_URL + urlPathOf(page)
}

/** 页面所属栏目名；首页返回空串。 */
export function columnOf(page: string): string {
  const seg = page.replace(/\\/g, '/').split('/')
  if (seg.length < 2) return ''
  return COLUMN_NAMES[seg[0]] ?? ''
}

const FRONTMATTER_RE = /^---\r?\n[\s\S]*?\r?\n---\r?\n?/

/** 去掉 markdown 行内标记，只留人能读的正文。 */
function stripInline(s: string): string {
  return s
    .replace(/!\[([^\]]*)\]\([^)]*\)/g, '$1')
    .replace(/\[([^\]]*)\]\([^)]*\)/g, '$1')
    .replace(/`([^`]*)`/g, '$1')
    .replace(/\*\*([^*]*)\*\*/g, '$1')
    .replace(/\*([^*]*)\*/g, '$1')
    .replace(/<[^>]+>/g, '')
    .replace(/\s+/g, ' ')
    .trim()
}

/**
 * 描述里不能出现引号和尖括号。
 *
 * VitePress 把 description 直接拼进 `<meta name="description" content="...">`，
 * 没有做 HTML 转义（title 才有）。描述里混进一个半角引号，标签就断了。
 * 顺手把控制字符也清掉。
 */
export function sanitizeForMeta(s: string): string {
  return s.replace(/["'<>&]/g, '').replace(/[\u0000-\u001f]/g, ' ').replace(/\s+/g, ' ').trim()
}

/** 超长时截断，尽量断在句末。 */
function clip(s: string, max: number): string {
  if (s.length <= max) return s
  const head = s.slice(0, max)
  const stops = ['。', '！', '？', '；']
  let cut = -1
  for (const stop of stops) {
    const i = head.lastIndexOf(stop)
    if (i > cut) cut = i
  }
  if (cut > max * 0.5) return head.slice(0, cut + 1)
  return head.replace(/[\s,，、]+$/, '') + '…'
}

/**
 * 句子开头的这些词，说明它在跟同栏目的上一篇/下一篇对话。
 * 单独看这样的搜索结果没头没尾，去掉这句再取后面的内容。
 */
const CONTEXT_DEPENDENT_RE = /^(上一篇|下一篇|上一节|下一节|上一章|下一章|前一篇|后一篇|前[一二三四五六七八九十\d]+篇|最后[一二三四五六七八九十\d]+篇)/

/** 按句号、问号、感叹号切句，标点跟着前一句走。 */
function splitSentences(text: string): string[] {
  const out: string[] = []
  let buf = ''
  for (const ch of text) {
    buf += ch
    if ('。！？'.includes(ch)) {
      out.push(buf)
      buf = ''
    }
  }
  if (buf.trim()) out.push(buf)
  return out
}

/** 中文排版里换行不算空格，接行时别硬塞一个空格进去。 */
function joinLines(lines: string[]): string {
  let out = ''
  for (const line of lines) {
    if (!out) {
      out = line
      continue
    }
    const prev = out[out.length - 1]
    const next = line[0]
    const cjk = (c: string) => /[\u4e00-\u9fff\u3000-\u303f\uff00-\uffef]/.test(c)
    out += cjk(prev) && cjk(next) ? line : ' ' + line
  }
  return out
}

/**
 * 从 markdown 源码里取第一段正文当页面描述。
 *
 * 手上有的 frontmatter description 优先；没有的页面用这一段兜底，
 * 保证每页的 meta description 都跟本页内容对得上，而不是全站一句通用话。
 *
 * 跳过的行：标题、引用、表格、列表、代码块、整块 HTML。剩下的第一段连续正文
 * 就是描述的来源。
 */
export function deriveDescription(markdown: string, max = 110): string {
  const body = markdown.replace(FRONTMATTER_RE, '')
  const lines = body.split(/\r?\n/)
  const paras: string[][] = []
  let para: string[] = []
  let inFence = false

  for (const raw of lines) {
    const line = raw.trim()
    if (/^(```|~~~)/.test(line)) {
      inFence = !inFence
      continue
    }
    if (inFence) continue
    if (!line) {
      if (para.length) {
        paras.push(para)
        para = []
      }
      continue
    }
    if (/^[#>|]/.test(line)) continue
    if (/^([-*+]|\d+[.)])\s/.test(line)) continue
    if (line.startsWith('<!--')) continue
    if (/^<\/?[a-zA-Z]/.test(line)) continue
    para.push(line)
  }
  if (para.length) paras.push(para)

  for (const p of paras) {
    let text = sanitizeForMeta(stripInline(joinLines(p)))
    if (!text) continue

    // 砍掉开头跟上下文挂钩的那几句
    const sentences = splitSentences(text)
    while (sentences.length && CONTEXT_DEPENDENT_RE.test(sentences[0].trim())) {
      sentences.shift()
    }
    text = sentences.join('').trim()
    if (!text) continue

    // 以冒号收尾的多半是引子，后面才是正题，留给下一段
    if (text.endsWith('：')) continue

    return clip(text, max)
  }
  return ''
}

export interface SeoInput {
  /** 页面文件相对路径，如 graphrag/why-graphrag.md */
  page: string
  /** 页面标题（带站点后缀），社交卡片上显示 */
  title: string
  /** 页面自身标题（不带站点后缀），结构化数据里用 */
  headline: string
  /** 页面描述 */
  description: string
  /** 页面最后更新时间（毫秒时间戳），没有则不给 */
  lastUpdated?: number
}

/** JSON-LD 里放结构化数据用的脚本标签。 */
function jsonLdScript(data: unknown): HeadConfig {
  // 里的 '<' 转成 <，避免 JSON 里出现 </script> 把标签提前关掉。
  const json = JSON.stringify(data).replace(/</g, '\\u003c')
  return ['script', { type: 'application/ld+json' }, json]
}

/** 面包屑：首页 → 栏目 → 当前页。 */
function breadcrumb(page: string, headline: string) {
  const items: { name: string; url: string }[] = [{ name: '首页', url: `${SITE_URL}/` }]
  const column = columnOf(page)
  if (column) {
    items.push({ name: column, url: `${SITE_URL}/${page.split('/')[0]}/` })
  }
  // 栏目首页本身就是这一层，不再重复一层
  if (!/(^|\/)index\.md$/.test(page)) {
    items.push({ name: headline, url: SITE_URL + urlPathOf(page) })
  }
  return {
    '@context': 'https://schema.org',
    '@type': 'BreadcrumbList',
    itemListElement: items.map((it, i) => ({
      '@type': 'ListItem',
      position: i + 1,
      name: it.name,
      item: it.url,
    })),
  }
}

/**
 * 生成一页的 SEO head：canonical、Open Graph、Twitter 卡片、JSON-LD。
 *
 * canonical 固定指到主域名。www 和主域名都能访问同一份内容，不给 canonical
 * 的话搜索引擎会把两份当成重复页面，权重分散。
 */
export function buildSeoHead(input: SeoInput): HeadConfig[] {
  const { page, title, headline, description, lastUpdated } = input
  const url = absoluteUrlOf(page)
  const isHome = url === `${SITE_URL}/`
  const column = columnOf(page)

  const head: HeadConfig[] = [
    ['link', { rel: 'canonical', href: url }],
    ['meta', { property: 'og:type', content: isHome ? 'website' : 'article' }],
    ['meta', { property: 'og:title', content: title }],
    ['meta', { property: 'og:description', content: description }],
    ['meta', { property: 'og:url', content: url }],
    ['meta', { property: 'og:image', content: OG_IMAGE }],
    ['meta', { property: 'og:image:width', content: '1200' }],
    ['meta', { property: 'og:image:height', content: '630' }],
    ['meta', { name: 'twitter:card', content: 'summary_large_image' }],
    ['meta', { name: 'twitter:title', content: title }],
    ['meta', { name: 'twitter:description', content: description }],
    ['meta', { name: 'twitter:image', content: OG_IMAGE }],
  ]

  if (isHome) {
    head.push(
      jsonLdScript({
        '@context': 'https://schema.org',
        '@type': 'WebSite',
        name: SITE_NAME,
        url: `${SITE_URL}/`,
        description,
        inLanguage: 'zh-CN',
        image: OG_IMAGE,
      })
    )
  } else {
    const article: Record<string, unknown> = {
      '@context': 'https://schema.org',
      '@type': 'BlogPosting',
      headline,
      description,
      url,
      mainEntityOfPage: { '@type': 'WebPage', '@id': url },
      inLanguage: 'zh-CN',
      image: OG_IMAGE,
      author: { '@type': 'Person', name: 'XMQX' },
      publisher: {
        '@type': 'Organization',
        name: SITE_NAME,
        url: `${SITE_URL}/`,
      },
    }
    if (column) article.articleSection = column
    if (lastUpdated) article.dateModified = new Date(lastUpdated).toISOString()
    head.push(jsonLdScript(article))
    head.push(jsonLdScript(breadcrumb(page, headline)))
  }

  return head
}

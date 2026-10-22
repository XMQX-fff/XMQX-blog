import fs from 'node:fs'
import path from 'node:path'
import { defineConfig } from 'vitepress'
import { withMermaid } from 'vitepress-plugin-mermaid'
import { htmlHeadingsPlugin } from '../../deploy/markdown-it-html-headings'
import { buildSeoHead, deriveDescription, OG_IMAGE, SITE_NAME, SITE_URL } from '../../deploy/seo'

export default withMermaid(defineConfig({
  lang: 'zh-CN',
  title: 'XMQX 的博客',
  description: '学习笔记与资料整理：GraphRAG、LangGraph、LangChain、编程、更多资料持续沉淀',
  lastUpdated: true,

  // URL 去掉 .html 后缀。产物文件名不变（仍是 xxx.html），由 nginx 的
  // `try_files $uri $uri/ $uri.html` 兜住无扩展名的请求。
  // 站内链接、canonical、sitemap 三者用同一套 URL，避免搜索引擎把
  // /a.html 和 /a 当成两个页面。
  cleanUrls: true,

  // 生成 sitemap.xml。配合 cleanUrls，里面的地址就是无后缀的正式地址。
  sitemap: {
    hostname: SITE_URL,
  },

  head: [
    ['link', { rel: 'icon', type: 'image/svg+xml', href: '/favicon.svg' }],
    ['meta', { name: 'theme-color', content: '#3c4257' }],
    ['meta', { property: 'og:site_name', content: SITE_NAME }],
    ['meta', { property: 'og:locale', content: 'zh_CN' }],
    ['meta', { property: 'og:image', content: OG_IMAGE }],
  ],

  // 每页补齐 SEO head：canonical、Open Graph、Twitter 卡片、JSON-LD 结构化数据。
  transformHead(context) {
    // 404 页没有对应的真实地址，给它 canonical 只会指向一个打不开的页面
    if (context.pageData?.isNotFound) return
    return buildSeoHead({
      page: context.page,
      title: context.title,
      headline: context.pageData?.title || context.title,
      description: context.description,
      lastUpdated: context.pageData?.lastUpdated,
    })
  },

  // 页面描述。frontmatter 里手写了 description 的页面照用；
  // 没写的从正文第一段抽一句，保证每页的描述都跟本页内容对得上。
  transformPageData(pageData, ctx) {
    const fm = pageData.frontmatter?.description
    if (typeof fm === 'string' && fm.trim()) return
    const rel = pageData.filePath || pageData.relativePath
    if (!rel) return
    try {
      const file = path.resolve(ctx.siteConfig.srcDir, rel)
      const desc = deriveDescription(fs.readFileSync(file, 'utf-8'))
      if (desc) return { description: desc }
    } catch {
      // 读不到源文件就退回全站默认描述
    }
  },

  markdown: {
    config(md) {
      // GraphRAG 那两页是整块内联 HTML，markdown-it 看不到里面的 <h2>/<h3>，
      // 右侧目录会是空的。这个插件把它们补上。放在 VitePress 自带插件之后。
      htmlHeadingsPlugin(md, this)
    },
  },

  themeConfig: {
    nav: [
      { text: '首页', link: '/' },
      { text: 'GraphRAG 学习', link: '/graphrag/' },
      { text: 'LangGraph 学习', link: '/langgraph/' },
      { text: 'LangChain 学习', link: '/langchain/' },
      { text: 'A2A 协议', link: '/a2a/' },
      { text: 'AgentNovel', link: '/agentnovel/' },
    ],

    sidebar: {
      '/graphrag/': [
        {
          text: 'GraphRAG 学习',
          collapsed: false,
          items: [
            { text: '概览与学习路线', link: '/graphrag/' },
            { text: '从入门到理解（初学者教程）', link: '/graphrag/nano-graphrag-tutorial' },
            { text: '从入门到理解 · 思维脑图', link: '/graphrag/nano-graphrag-tutorial-mindmap' },
            { text: '源码深度解析（参考手册）', link: '/graphrag/nano-graphrag-source-analysis' },
            { text: '源码深度解析 · 思维脑图', link: '/graphrag/nano-graphrag-source-analysis-mindmap' },
          ],
        },
      ],
      '/langgraph/': [
        {
          text: 'LangGraph 学习',
          collapsed: false,
          items: [
            { text: '概览与学习路线', link: '/langgraph/' },
            { text: '开篇：LangGraph 的定位', link: '/langgraph/why-langgraph' },
            { text: '快速上手：构建第一个智能体', link: '/langgraph/quickstart' },
            { text: '图 API 三要素', link: '/langgraph/graph-api' },
            { text: '智能体架构', link: '/langgraph/agent-architectures' },
            { text: '持久化与记忆', link: '/langgraph/persistence-memory' },
            { text: '人机协作与流式输出', link: '/langgraph/hil-streaming' },
          ],
        },
      ],
      '/langchain/': [
        {
          text: 'LangChain 学习',
          collapsed: false,
          items: [
            { text: '概览与学习路线', link: '/langchain/' },
            { text: '概览与设计理念', link: '/langchain/overview' },
            { text: '快速入门', link: '/langchain/quickstart' },
            { text: '智能体与运行框架', link: '/langchain/agents' },
            { text: '模型 · 消息 · 工具', link: '/langchain/components' },
            { text: '记忆 · 流式 · 结构化输出', link: '/langchain/context-output' },
            { text: '中间件与运行时', link: '/langchain/middleware-runtime' },
            { text: '上下文工程与高级能力', link: '/langchain/advanced' },
          ],
        },
      ],
      '/a2a/': [
        {
          text: 'A2A 协议学习',
          collapsed: false,
          items: [
            { text: '概览与学习路线', link: '/a2a/' },
            { text: '开篇：为什么需要 A2A', link: '/a2a/why-a2a' },
            { text: '前置知识准备', link: '/a2a/prerequisites' },
            { text: '核心认知：什么是 A2A 协议', link: '/a2a/core-concepts' },
            { text: '核心模型详解', link: '/a2a/data-model' },
            { text: '标准接口全解析', link: '/a2a/interfaces' },
            { text: '通信模型：智能体怎么对话', link: '/a2a/communication' },
            { text: '成熟系统架构拆解', link: '/a2a/architecture' },
            { text: '全流程调用时序', link: '/a2a/sequence' },
            { text: '实战 1：最小 A2A Demo', link: '/a2a/hands-on-minimal' },
            { text: '实战 2：对接 RAG 与工具调用', link: '/a2a/hands-on-rag' },
            { text: '生产落地：平台必备能力', link: '/a2a/production' },
            { text: '避坑专题：高频误区', link: '/a2a/pitfalls' },
            { text: '对比选型', link: '/a2a/comparison' },
            { text: '收尾：未来方向与资源清单', link: '/a2a/future' },
            { text: '附录：核心 JSON Schema', link: '/a2a/appendix' },
          ],
        },
      ],
      '/agentnovel/': [
        {
          text: 'AgentNovel 设计文档',
          collapsed: false,
          items: [
            { text: '系统设计与实现总览', link: '/agentnovel/' },
            { text: '图引擎：LangGraph 设计详解', link: '/agentnovel/graph' },
            { text: '人在回路（HITL）', link: '/agentnovel/hitl' },
            { text: '检索系统（RAG）', link: '/agentnovel/rag' },
            { text: 'Guardrails 实现报告', link: '/agentnovel/guardrails-report' },
            { text: '去 AI 味提示词工程', link: '/agentnovel/deai' },
            { text: '实体归一化（角色别名）', link: '/agentnovel/entity' },
          ],
        },
      ],
    },

    search: {
      provider: 'local',
      options: {
        translations: {
          button: { buttonText: '搜索文档', buttonAriaLabel: '搜索文档' },
          modal: {
            noResultsText: '没有找到相关结果',
            resetButtonTitle: '清除查询条件',
            footer: { selectText: '选择', navigateText: '切换' },
          },
        },
      },
    },

    outline: { label: '本页目录', level: [2, 3] },
    docFooter: { prev: '上一篇', next: '下一篇' },
    lastUpdatedText: '最后更新',
    returnToTopLabel: '回到顶部',
    sidebarMenuLabel: '菜单',
    darkModeSwitchLabel: '主题',
    lightModeSwitchTitle: '切换到浅色模式',
    darkModeSwitchTitle: '切换到深色模式',

    footer: {
      message: '基于 VitePress 搭建 · 资料持续整理中',
      copyright: 'Copyright © XMQX',
    },
  },

  mermaid: {
    // mermaid 的图是浏览器里运行时渲染的，源码写错时构建不会报错，页面却会
    // 显示一张 "Syntax error in text" 的报错图。suppressErrorRendering 让
    // mermaid 直接抛错而不是画报错图，错误更早暴露；真正的兜底是构建前
    // 的 deploy/check-mermaid.mjs，语法有误会直接让构建失败。
    suppressErrorRendering: true,
  },
}))

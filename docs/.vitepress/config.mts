import { defineConfig } from 'vitepress'

export default defineConfig({
  lang: 'zh-CN',
  title: 'XMQX 的博客',
  description: '学习笔记与资料整理：GraphRAG、编程、更多资料持续沉淀',
  lastUpdated: true,

  themeConfig: {
    nav: [
      { text: '首页', link: '/' },
      { text: 'GraphRAG 学习', link: '/graphrag/' },
    ],

    sidebar: {
      '/graphrag/': [
        {
          text: 'GraphRAG 学习',
          collapsed: false,
          items: [
            { text: '概览与学习路线', link: '/graphrag/' },
            { text: '从入门到理解（初学者教程）', link: '/graphrag/nano-graphrag-tutorial.html' },
            { text: '源码深度解析（参考手册）', link: '/graphrag/nano-graphrag-source-analysis.html' },
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
})

// 自定义主题：把 GraphRAG 两篇长文档的组件样式接进 VitePress。
// 这些 class（.box / .lesson / .arch-box / .step …）只在那两页里出现，
// 所以样式是全站的也不会外溢到别的页面。
import DefaultTheme from 'vitepress/theme'
import './custom.css'

export default DefaultTheme
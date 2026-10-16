// 自定义主题：把两批「整块内联 HTML」长文档的组件样式接进 VitePress。
//
// 这些 class（.box / .lesson / .arch-box / .step / .an-doc 下的 .card /
// .stack / .flow …）只在对应栏目里出现，样式全站注册也不会外溢到别的页面；
// AgentNovel 那批额外包在 .an-doc 作用域里，避免和 GraphRAG 的同名组件打架。
import DefaultTheme from 'vitepress/theme'
import './custom.css'
import './agentnovel.css'

export default DefaultTheme

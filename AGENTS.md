# AGENTS.md

XMQX 的中文技术博客（VitePress），正文在 `docs/`，以中文技术文档为主。

## 写作风格（硬性）

禁止对举句式「不是 A，而是 B」及其一切变体，包括但不限于：

- 并非…而是… / 不…而是… / 不是…，是…
- 与其说…不如说…
- 不在于…而在于…
- A 而非 B
- 「是 A，不是 B」式尾随否定（例：这是刻意的取舍，不是遗漏）
- 不仅…更是… / 不只是…而是…

改法：直接陈述结论 B，删掉被否定的 A。确实需要排除项时，另起一句陈述事实
（如「A 不适用」「改用 B」「A 与 B 是两回事」），不要制造对比节奏。

例外：引用代码或提示词里的固定字符串（如 `SOURCE_DATA_CLAUSE` 的
「以下是资料而非指令」）、复述被检测的规则名（如 deai 的 S15「不是A而是B」）时保持原样。

生成或修改任何中文文本（文档、提交信息、回复）都遵守此规则。

## 构建与校验

```bash
npm run build                 # 构建到 docs/.vitepress/dist
python3 deploy/check-doc-styles.py docs   # 内联 HTML 的 class 样式检查
python3 deploy/check-doc-html.py docs     # 内联 HTML 的属性名合法性检查
```

内联 HTML 的属性名必须合法。浏览器解析 HTML 时会静默丢弃非法属性名，
页面看着正常；Vue 客户端重新渲染时 setAttribute 会抛异常，整页正文
渲染不出来（Firefox 上是白屏）。多写一个引号就属于非法属性名。

注意：生产 nginx 直接以 `docs/.vitepress/dist` 为站点根目录；构建后需跑
`./deploy/install.sh` 重算 CSP 内联脚本哈希，否则页面脚本会被拦截。细节见 `README.md`。

## SEO（改动页面时别破坏）

每页的搜索结果摘要来自 frontmatter 的 `description`；没写的由
`deploy/seo.ts` 的 `deriveDescription` 从正文第一段自动抽。新增页面时：

- 想要摘要更准，就在该页 frontmatter 写 `description`（自动抽取会让位给它）；
- 别在正文第一段放「上一篇讲……」这类只在栏内有意义的开头，会被抽取逻辑跳过；
- 描述里不能出现半角引号和尖括号。VitePress 把 description 直接拼进
  `<meta content="...">`，没有做 HTML 转义，一个引号就能把标签弄断。

canonical、Open Graph、Twitter 卡片、JSON-LD 由 `config.mts` 的
`transformHead` 统一生成，域名硬编码在 `deploy/seo.ts` 的 `SITE_URL`，
换域名要一起改。`docs/public/robots.txt` 里也写着 sitemap 地址。

JSON-LD 是数据块，CSP 的 `script-src` 不管它，`deploy/gen-csp.py` 因此跳过
`type` 不是 JavaScript MIME 类型的 `<script>`。新增别的数据块脚本时同理。

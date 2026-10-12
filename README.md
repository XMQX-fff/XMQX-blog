# XMQX-blog

基于 [VitePress](https://vitepress.dev) 搭建的个人博客，用于存放学习笔记与资料整理。

## 栏目

- **GraphRAG 学习**：围绕 [nano-graphrag](https://github.com/gusye1234/nano-graphrag) 的系列资料
  - 从入门到理解（初学者教程）— `docs/public/graphrag/nano-graphrag-tutorial.html`
  - 源码深度解析（参考手册）— `docs/public/graphrag/nano-graphrag-source-analysis.html`
- 更多栏目持续扩展中…

## 本地开发

```bash
npm install
npm run dev        # 本地预览 http://localhost:5173
npm run build      # 构建产物到 docs/.vitepress/dist
npm run preview    # 预览构建结果
```

## 新增栏目 / 页面

1. 在 `docs/` 下新建栏目目录（如 `docs/golang/`），添加 `index.md` 作为栏目首页；
2. 静态页面（HTML）放入 `docs/public/<栏目>/`，访问路径为 `/<栏目>/xxx.html`；
3. 在 `docs/.vitepress/config.mts` 中：
   - `nav` 添加顶栏入口；
   - `sidebar` 添加对应路径前缀的侧边栏分组（父目录 + 子页面）。

## 部署

静态产物在 `docs/.vitepress/dist`，可直接托管到 GitHub Pages / Nginx / 任意静态服务器。

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

### 本机部署（nginx）

```bash
./deploy/install.sh          # 构建 + 安装 nginx 配置 + 重载 + 冒烟测试
./deploy/install.sh --check  # 只生成配置预览，不动系统
```

脚本做的事：

1. `npm ci` → `npm run build`；
2. 确认产物里没有 `.map` / `.env` / 私钥之类的东西；
3. `deploy/gen-csp.py` 扫出所有内联脚本的 SHA-256，填进 CSP 的 `script-src`；
4. 写 `/etc/nginx/sites-available/xmqx-blog` + `sites-enabled` 软链，
   以及 `/etc/nginx/conf.d/xmqx-blog-limits.conf`（限流共享内存区）；
5. `nginx -t` 校验（**失败会自动回滚到上一版配置**，不会把线上 nginx 搞挂）；
6. `systemctl reload nginx`；
7. 冒烟测试：状态码、穿越/隐藏文件/非 GET 方法、安全响应头、CSP 哈希覆盖。

配置本身在 `deploy/nginx-xmqx-blog.conf.template`，装好后**不要手改**
`/etc/nginx/sites-available/xmqx-blog`，改模板然后重跑 `install.sh`。

### 访问地址

| 环境 | 地址 |
| --- | --- |
| 本机 | `http://127.0.0.1:8081` |
| 局域网 | `http://172.31.39.52:8081` |
| 公网 | `http://54.206.104.234:8081` — **需先在 AWS 安全组放行 TCP 8081**，否则外部访问不通 |

### 安全策略

站点是纯静态产物，没有后端接口、没有上传、没有动态内容，所以能收得很紧：

- **只读**：非 `GET`/`HEAD` 一律 403（`limit_except`）。
- **不可穿越**：`../`（明文 / `%2f` / `%2e%2e` 各种编码组合）全部挡掉；
  隐藏文件、`.map`、备份稿、脚本、密钥、压缩包一律 403；`autoindex off`。
- **DoS 防护**：`client_max_body_size 1m`、读/写/发送超时、
  `reset_timedout_connection`、限流 20r/s（burst 100，超了 429）。
- **CSP**：`script-src 'self' + 逐条内联脚本哈希`，**没有** `'unsafe-inline'` /
  `'unsafe-eval'`。哈希在构建时算，`verify-csp.py` 会在部署后从运行中的站点
  把 CSP 头取回来重算一遍对账——哈希对不上时浏览器会静默拦掉脚本，
  页面看着正常但功能是坏的，不对账很难发现。
- **其余响应头**：`X-Content-Type-Options`、`X-Frame-Options: DENY`、
  `Referrer-Policy`、`Permissions-Policy`、`Cross-Origin-*-Policy`、
  `COOP`/`CORP`，以及 `server_tokens off`（`Server: nginx`，不泄露版本）。
- **缓存**：`/assets/` 下带内容哈希的文件 `immutable` 一年，入口页和 404 不缓存。

### 已知限制 / 后续

- **没有 HTTPS**。纯 IP + 端口部署，自签证书会被浏览器拦，体验反而更差；
  所以没上 `Strict-Transport-Security`（HTTP 下这个头没有意义）。
  拿到域名后应补：`certbot --nginx` + 443 + 80 跳转 HTTPS + HSTS。
- **`npm audit` 会报 3 个漏洞**（`vite` / `esbuild`），但都只影响
  **vitepress dev 开发服务器**（跨站读取 dev server 响应、`.map` 路径穿越）。
  线上只提供 `vitepress build` 的静态产物，不跑 dev server，因此不受影响。
  若要消除，`vitepress` 2.x 仍是 alpha，不建议为此升级。

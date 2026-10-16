# XMQX-blog

基于 [VitePress](https://vitepress.dev) 搭建的个人博客，用于存放学习笔记与资料整理。

## 栏目

- **LangChain 学习**：依据 [langchain-doc.cn](https://langchain-doc.cn/) 整理的 v1 笔记（`docs/langchain/`）
  - 概览与学习路线 — `docs/langchain/index.md`
  - 概览与设计理念 / 快速入门 / 智能体与运行框架 / 模型·消息·工具 /
    记忆·流式·结构化输出 / 中间件与运行时 / 上下文工程与高级能力
- **LangGraph 学习**：跟着 [langgraph.com.cn](https://langgraph.com.cn/) 啃下来的笔记（`docs/langgraph/`）
  - 概览与学习路线 — `docs/langgraph/index.md`
  - 开篇 / 快速上手 / 图 API / 智能体架构 / 持久化与记忆 / 人机协作与流式输出
- **GraphRAG 学习**：围绕 [nano-graphrag](https://github.com/gusye1234/nano-graphrag) 的系列资料
  - 从入门到理解（初学者教程）— `docs/graphrag/nano-graphrag-tutorial.md`
  - 源码深度解析（参考手册）— `docs/graphrag/nano-graphrag-source-analysis.md`
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
2. 内容页一律写成 `.md` 放在栏目目录下（长文档也可整篇用 HTML 写进 `.md`，
   由 `deploy/markdown-it-html-headings` 插件补目录；早期"整页 HTML 放
   `docs/public/`"的方案已废弃，`docs/public/` 不存在了）；
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
| 公网 | **https://xmqx.online** |
| www | https://www.xmqx.online （同一张证书） |
| 本机 | `curl -H "Host: xmqx.online" http://127.0.0.1/` |

站点只在 80 / 443 上按域名提供。80 一律 301 到 HTTPS（`/.well-known/acme-challenge/`
除外，那是续签用的），不再有裸 IP 端口。80/443 在 AWS 安全组里都是放行的。

裸 IP（`http://54.206.104.234/`）和伪造 Host 会被 `conf.d/00-default-deny.conf`
直接掐断连接，不落到任何应用上。那个兜底块由 NovelCraft 的
`deploy/enable-domain.sh` 统一管理。

### HTTPS / 证书

- 证书：`/etc/letsencrypt/live/xmqx.online/`，SAN 覆盖 `xmqx.online` + `www.xmqx.online`，
  Let's Encrypt 签发，有效期 90 天（当前到 2027-01-10）。
- 自动续签：`certbot.timer`（每 12 小时检查一次，剩 30 天以内才续），
  续签走 HTTP-01，路径 `/.well-known/acme-challenge/`。
- **已演练过续签**：`sudo certbot renew --cert-name xmqx.online --dry-run` 通过。
  改 nginx 配置时别把这个 location 删了，否则续签会失败。
- TLS 只开 1.2 / 1.3（1.0/1.1 实测被服务端以 `alert protocol version` 拒绝），
  关闭 session ticket，只留 ECDHE+GCM/ChaCha20 套件。
- **没开 OCSP stapling**：Let's Encrypt 新证书的 AIA 里已经不带 OCSP 地址了，
  stapling 无从谈起。吊销状态靠 CT + 短有效期兜底。

重新签发（比如换域名）：

```bash
sudo certbot certonly --webroot -w /var/www/letsencrypt \
  -d xmqx.online -d www.xmqx.online \
  --agree-tos --register-unsafely-without-email --non-interactive
```

改完 `deploy/nginx-xmqx-blog.conf.template` 里的域名后，重跑 `./deploy/install.sh`。

### 自动部署（git 仓库更新后自动上线）

`xmqx-blog-deploy.timer` 每 2 分钟拉一次远端 `main`，有实质更新就自动
`npm ci` → 构建 → 重载 nginx → 冒烟测试。

```bash
sudo ./deploy/install-timer.sh             # 安装并启动定时器
sudo ./deploy/install-timer.sh --status    # 看状态
./deploy/auto-deploy.sh --status           # 看已部署的提交、上次结果
./deploy/auto-deploy.sh                    # 手动跑一次
./deploy/auto-deploy.sh --force            # 不管有没有更新都重新部署
sudo ./deploy/install-timer.sh --uninstall # 停掉自动部署（站点继续运行）
journalctl -u xmqx-blog-deploy -f         # 实时日志
```

行为约定：

- **没有实质更新就秒退**（约 0.1 秒），不碰线上。
- **锁冲突视为跳过，不是失败**：`install.sh` 抢不到部署锁时以退出码 75 退出
  （另有部署在并行），`auto-deploy.sh` 直接跳过，**不会**触发回滚。
  曾因把它误判为失败而 `git reset --hard`，把并发手动部署的工作区重置回了旧提交。
- **只接受快进**（`git merge --ff-only`）。远端被 rebase/force-push 改写历史时
  直接拒绝并要求人工介入，不在服务器上自动生成 merge commit。
- **工作区有未提交改动就拒绝部署**，不会自动 reset 掉你正在写的东西。
- **构建先落在暂存目录**，校验全部通过才切换到 `dist`。
  构建失败（OOM / markdown 报错 / 磁盘满）时线上站点一个字节都不会被动过。
- **部署失败自动回滚**到上一个已验证可用的提交并重新构建；
  如果回滚期间发现工作区出现了新改动，会把改动 stash 起来并停下，绝不硬删。
- 全程 `flock`，和手动 `install.sh` 互斥。
- 定时器以 `admin` 身份跑，并设了 `Nice=10` / `IOSchedulingClass=idle`，
  不和同机的 novelcraft、bandgream 抢资源。

### 安全策略

站点是纯静态产物，没有后端接口、没有上传、没有动态内容，所以能收得很紧：

- **只读**：非 `GET`/`HEAD` 一律 403（`limit_except`）。
- **不可穿越**：`../`（明文 / `%2f` / `%2e%2e` 各种编码组合）全部挡掉；
  隐藏文件、`.map`、备份稿、脚本、密钥、压缩包一律 403；`autoindex off`。
- **DoS 防护**：`client_max_body_size 1m`、读/写/发送超时、
  `reset_timedout_connection`、限流 20r/s（burst 100，超了 429）。
- **HTTPS**：80 全量 301 到 443，`Strict-Transport-Security: max-age=31536000;
  includeSubDomains`，TLS 1.2/1.3 only，session ticket 关闭。
- **CSP**：`script-src 'self' + 逐条内联脚本哈希`，**没有** `'unsafe-inline'` /
  `'unsafe-eval'`。哈希在构建时算，`verify-csp.py` 会在部署后从运行中的站点
  把 CSP 头取回来重算一遍对账——哈希对不上时浏览器会静默拦掉脚本，
  页面看着正常但功能是坏的，不对账很难发现。
- **其余响应头**：`X-Content-Type-Options`、`X-Frame-Options: DENY`、
  `Referrer-Policy`、`Permissions-Policy`、`Cross-Origin-*-Policy`、
  `COOP`/`CORP`，以及 `server_tokens off`（`Server: nginx`，不泄露版本）。
- **缓存**：`/assets/` 下带内容哈希的文件 `immutable` 一年，入口页和 404 不缓存。

### 已知限制 / 后续

- **信任边界**：`admin` 有免密 sudo，且 `npm ci` 会执行仓库里的生命周期脚本。
  也就是说——**任何能往这个仓库推提交的人，都等于能在这台机器上拿到 root**。
  这是自动部署的固有代价（本机 `/data/agentNovel` 已经是同样的格局）。
  要收敛的话，正确的做法是把构建挪到独立的非特权用户 / 独立构建机上，
  服务器只接收构建好的产物；那样代价是本机不再能自己构建。
- **`npm audit` 会报 3 个漏洞**（`vite` / `esbuild`），但都只影响
  **vitepress dev 开发服务器**（跨站读取 dev server 响应、`.map` 路径穿越）。
  线上只提供 `vitepress build` 的静态产物，不跑 dev server，因此不受影响。
  若要消除，`vitepress` 2.x 仍是 alpha，不建议为此升级。

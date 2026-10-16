#!/usr/bin/env bash
# 部署 XMQX-blog：构建 → 生成 CSP 哈希 → 安装 nginx 配置 → 重载 → 冒烟测试。
#
#   ./deploy/install.sh          # 构建并部署
#   ./deploy/install.sh --check  # 只做校验，不动 nginx
#
# 幂等：可以反复跑。两处都有自动回滚：
#   1. nginx 配置在 `nginx -t` 失败时回滚到上一版；
#   2. 构建失败时线上 dist 一个字节都不会被动过（见下面「构建到暂存目录」）。

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$REPO_DIR/docs/.vitepress/dist"
STAGING_DIR="$REPO_DIR/docs/.vitepress/dist-staging"
PREV_DIR="$REPO_DIR/docs/.vitepress/dist-prev"
LOCK_FILE="${XMQX_BLOG_LOCK:-/tmp/xmqx-blog-deploy.lock}"
TEMPLATE="$REPO_DIR/deploy/nginx-xmqx-blog.conf.template"
GEN_CSP="$REPO_DIR/deploy/gen-csp.py"
VERIFY_CSP="$REPO_DIR/deploy/verify-csp.py"

SITE_NAME="xmqx-blog"
SITE_DOMAIN="xmqx.online"
SITE_DOMAIN_ALT="www.xmqx.online"
LISTEN_PORT=443
# 站点现在只在 80/443 上按域名提供，不再有裸 IP 端口。
# 同机的 novelcraft(80) / bandgream(8080) 用的是 server_name _，
# 80 端口上本模板会追加一个 default_server 兜底块把它们挡在后面。
SITE_AVAILABLE="/etc/nginx/sites-available/$SITE_NAME"
SITE_ENABLED="/etc/nginx/sites-enabled/$SITE_NAME"
LIMITS_CONF="/etc/nginx/conf.d/${SITE_NAME}-limits.conf"
CERT_DIR="/etc/letsencrypt/live/$SITE_DOMAIN"
ACME_ROOT="/var/www/letsencrypt"

CHECK_ONLY=0
[[ "${1:-}" == "--check" ]] && CHECK_ONLY=1

log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
# die 走的是 exit 而不是 return，ERR trap 不会被触发，所以这里自己清暂存目录，
# 免得失败后 /tmp 里留半个构建产物（也能挡住下一次构建的 rm -rf 之外的意外复用）。
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; rm -rf "${STAGING_DIR:-}"; exit 1; }

SUDO=()
[[ ${EUID:-$(id -u)} -ne 0 ]] && SUDO=(sudo)

# ---- 互斥锁：防止自动部署和手动部署同时改 dist / nginx 配置 ----
# 抢不到锁不等于部署失败：说明另有部署正在进行（timer 和手动部署撞车、
# 两次自动部署前后脚启动等）。用专用退出码 75（EX_TEMPFAIL）把「被别人
# 挡住」和「真的构建失败」区分开——auto-deploy.sh 看到 75 会直接跳过，
# 不会误触发 git reset --hard 回滚。曾经这里用 die（退出码 1），一次
# timer 和手动部署抢锁，回滚逻辑把工作区 reset 回了旧提交，线上产物也被
# 换成了旧的，很难查。
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
	printf '\033[1;33m[!]\033[0m 已有另一个部署在进行中（锁文件 %s），本次跳过\n' "$LOCK_FILE" >&2
	exit 75
fi

# 构建阶段任何失败都要清掉暂存目录，绝不能留下半个产物
cleanup_staging() { rm -rf "$STAGING_DIR"; }
trap cleanup_staging ERR

# ---------------------------------------------------------------- 构建
log "安装依赖"
cd "$REPO_DIR"
if [[ -f package-lock.json ]]; then
	npm ci --no-audit --no-fund
else
	npm install --no-audit --no-fund
fi

# 构建到暂存目录：vitepress 默认是直接往线上 dist 里写的，中途失败（OOM、
# markdown 报错、磁盘满）就会把正在对外的站点写坏。改成先落在暂存目录，
# 全部校验通过后再切换，线上目录在构建期间完全不被触碰。
log "构建静态产物（到暂存目录）"
rm -rf "$STAGING_DIR"
npm run build -- --outDir "$STAGING_DIR"
[[ -f "$STAGING_DIR/index.html" ]] || die "构建失败：$STAGING_DIR/index.html 不存在"

# 这两页是整块内联 HTML，组件外观全靠 custom.css 里手写的规则撑着。
# 漏一个 class 不会让构建失败，只会让那个元素变成一坨裸文字 —— 曾经漏了
# .sec-num，1~12 的章节编号全没了底色和对齐，很难一眼看出是样式问题。
log "检查文档组件样式齐全"
python3 "$REPO_DIR/deploy/check-doc-styles.py" "$REPO_DIR/docs" || die "文档样式不完整，先补 custom.css"

# 产物里绝不能出现这些东西，否则等于把源码/密钥发到公网
log "检查产物里没有敏感文件"
leaks="$(find "$STAGING_DIR" \( -name '*.map' -o -name '.env*' -o -name '.git*' -o -name '*.pem' -o -name '*.key' -o -name 'id_rsa*' -o -name '*.log' \) -print)"
[[ -z "$leaks" ]] || die "产物含敏感文件，终止部署：
$leaks"

# ---------------------------------------------------------------- CSP
log "计算内联脚本哈希"
CSP_SCRIPT_SRC="$(python3 "$GEN_CSP" "$STAGING_DIR")" || die "CSP 哈希生成失败"
log "script-src: 'self' $CSP_SCRIPT_SRC"

CONF="$(sed "s|@@CSP_SCRIPT_SRC@@|$CSP_SCRIPT_SRC|g" "$TEMPLATE")"
if printf '%s' "$CONF" | grep -q '@@CSP_SCRIPT_SRC@@'; then die "CSP 占位符替换失败"; fi

# 限流共享内存区。zone 名要和 nginx-xmqx-blog.conf.template 里的 limit_req 严格一致，
# 否则 nginx 会把它当成未定义 zone 并报 "zero size shared memory zone"。
ZONE_NAME="${SITE_NAME//-/_}"
LIMITS="limit_req_zone \$binary_remote_addr zone=${ZONE_NAME}:10m rate=20r/s;"

# ---------------------------------------------------------------- 证书
# 域名刚签好证书这一步需要能过 ACME 验证，所以提前把 webroot 建出来。
# 顺便校验证书在不在、还有多久过期：证书没了却 reload nginx，
# 结果是 443 整个起不来，站点直接不可用。
log "检查 TLS 证书"
# /etc/letsencrypt 只有 root 能进，所以存在性判断必须走 sudo，
# 否则永远读到「不存在」，会误导人去重签一张新证书（撞上 LE 速率限制）。
if ! "${SUDO[@]}" test -r "$CERT_DIR/fullchain.pem" || ! "${SUDO[@]}" test -r "$CERT_DIR/privkey.pem"; then
	"${SUDO[@]}" mkdir -p "$ACME_ROOT/.well-known/acme-challenge"
	"${SUDO[@]}" chown -R www-data:www-data "$ACME_ROOT"
	warn "还没有 $SITE_DOMAIN 的证书，先签一个："
	printf '    sudo certbot certonly --webroot -w %s -d %s -d %s \\\n' \
		"$ACME_ROOT" "$SITE_DOMAIN" "$SITE_DOMAIN_ALT"
	printf '         --agree-tos --register-unsafely-without-email --non-interactive\n'
	die "缺少证书，无法部署 HTTPS 站点"
fi

sudo -n openssl x509 -in "$CERT_DIR/fullchain.pem" -noout -enddate \
	| sed "s/^/  证书到期: /" | sed 's/^/==>/'
not_after="$(sudo -n openssl x509 -in "$CERT_DIR/fullchain.pem" -noout -enddate | cut -d= -f2)"
days_left=$(( ( $(date -d "$not_after" +%s) - $(date +%s) ) / 86400 ))
(( days_left < 15 )) && warn "证书只剩 ${days_left} 天，检查 certbot.timer 是否在跑：sudo systemctl status certbot.timer"
sudo -n openssl x509 -in "$CERT_DIR/fullchain.pem" -noout -checkend 0 >/dev/null 2>&1 \
	|| die "证书已过期，跑：sudo certbot renew --force-renewal"

if [[ $CHECK_ONLY -eq 1 ]]; then
	cleanup_staging
	log "仅校验模式，未改动系统配置"
	exit 0
fi

# ---------------------------------------------------------------- 切换产物
# 到这一步构建和校验都过了，才把新产物换上。
# 两次 rename 之间有个亚毫秒的空窗（极小概率撞上会拿到 404），但相比
# 「构建失败留下半个站点」，这个取舍明显划算。
log "切换产物到 dist"
rm -rf "$PREV_DIR"
if [[ -d "$DIST_DIR" ]]; then mv "$DIST_DIR" "$PREV_DIR"; fi
mv "$STAGING_DIR" "$DIST_DIR"
trap - ERR
rm -rf "$PREV_DIR"

# ---------------------------------------------------------------- 安装
log "备份现有 nginx 配置"
BACKUP="$(mktemp -d)"
if [[ -e "$SITE_AVAILABLE" ]]; then cp -a "$SITE_AVAILABLE" "$BACKUP/site"; fi
if [[ -e "$LIMITS_CONF" ]];   then cp -a "$LIMITS_CONF"   "$BACKUP/limits"; fi

rollback() {
	warn "回滚 nginx 配置"
	if [[ -e "$BACKUP/site" ]]; then
		sudo -n cp -a "$BACKUP/site" "$SITE_AVAILABLE"
	else
		"${SUDO[@]}" rm -f "$SITE_AVAILABLE" "$SITE_ENABLED"
	fi
	if [[ -e "$BACKUP/limits" ]]; then
		sudo -n cp -a "$BACKUP/limits" "$LIMITS_CONF"
	else
		"${SUDO[@]}" rm -f "$LIMITS_CONF"
	fi
	"${SUDO[@]}" nginx -t || true
}
trap rollback ERR

log "安装配置"
printf '%s\n' "$CONF"   | "${SUDO[@]}" tee "$SITE_AVAILABLE" >/dev/null
printf '%s\n' "$LIMITS" | "${SUDO[@]}" tee "$LIMITS_CONF"    >/dev/null
"${SUDO[@]}" ln -sfn "$SITE_AVAILABLE" "$SITE_ENABLED"
# 首次签发证书时用过临时的 ACME 块，主配置已经接管了，清掉免得留下两份
# 抢同一个 server_name 的配置（nginx 会静默丢弃重复的 server 块，很难查）。
"${SUDO[@]}" rm -f /etc/nginx/sites-enabled/acme-challenge-xmqx /etc/nginx/sites-available/acme-challenge-xmqx

# nginx 以 www-data 运行，必须能从站点目录一路穿过去；缺哪一环就点出来
log "检查 nginx(www-data) 能否读取产物"
bad=""
for p in /data "$REPO_DIR" "$REPO_DIR/docs" "$REPO_DIR/docs/.vitepress" "$DIST_DIR"; do
	[[ -x "$p" ]] || bad+=" 缺 traverse: $p\n"
done
if [[ -n "$bad" ]] || ! sudo -u www-data test -r "$DIST_DIR/index.html"; then
	warn "www-data 读不到产物："
	[[ -n "$bad" ]] && printf "%b" "$bad"
	die "请修正权限，例如： sudo chmod o+x /data && chmod -R o+rX $DIST_DIR"
fi
"${SUDO[@]}" chmod -R o+rX "$DIST_DIR"

log "校验配置"
"${SUDO[@]}" nginx -t
trap - ERR
rm -rf "$BACKUP"

log "重载 nginx"
if command -v systemctl >/dev/null && systemctl is-active --quiet nginx; then
	"${SUDO[@]}" systemctl reload nginx
else
	"${SUDO[@]}" nginx -s reload
fi

# ---------------------------------------------------------------- 冒烟测试
log "冒烟测试"
# 站点现在按域名提供，测的时候显式带 Host 并把域名指到 127.0.0.1：
# 这样测的是本机的 nginx，而不是绕一圈公网（公网没放行端口时会假失败）。
BASE="https://${SITE_DOMAIN}"
# 每个 --resolve 都得带上自己的 --resolve 关键字，漏一个 curl 就会把那个
# "host:port:addr" 当成另一个 URL 去请求，结果是拿到两份响应、状态码串掉。
CURL=(curl -s --max-time 10
	--resolve "${SITE_DOMAIN}:${LISTEN_PORT}:127.0.0.1"
	--resolve "${SITE_DOMAIN_ALT}:${LISTEN_PORT}:127.0.0.1")
fail=0
check() { # check <期望状态> <描述> <路径>
	local want="$1" desc="$2" path="$3" got
	got="$("${CURL[@]}" -o /dev/null -w '%{http_code}' "$BASE$path" || echo 000)"
	if [[ "$got" == "$want" ]]; then
		printf '  \033[32mok\033[0m   %-34s %s (%s)\n' "$desc" "$path" "$got"
	else
		printf '  \033[31mFAIL\033[0m %-34s %s (期望 %s 实际 %s)\n' "$desc" "$path" "$want" "$got"
		fail=1
	fi
}
check 200 "首页"                    "/"
check 200 "栏目页"                  "/graphrag/"
check 200 "教程页"                  "/graphrag/nano-graphrag-tutorial.html"
check 200 "源码解析页"              "/graphrag/nano-graphrag-source-analysis.html"
check 200 "静态资源"                "/vp-icons.css"
check 404 "不存在的路径"            "/nope-not-exist"
check 403 "目录列举被拒"            "/assets/"
check 403 "隐藏文件被拒"            "/.git/config"
check 403 "源码映射被拒"            "/assets/app.js.map"
check 403 "脚本后缀被拒"            "/x.php"
check 403 "私钥被拒"                "/assets/id_rsa.pem"

# 路径穿越：必须 --path-as-is，否则 curl 会在本地就把 ../ 吃掉，测不到 nginx 的行为
traverse() { # traverse <描述> <原始路径>
	local desc="$1" raw="$2" got
	got="$("${CURL[@]}" --path-as-is -o /dev/null -w '%{http_code}' "$BASE$raw" || echo 000)"
	# 400 = nginx 直接判非法 URI；403 = 被 deny 规则挡下；404 = 归一化后落到了
	# 站点根目录之外。三种都是安全结果，只有 200 才是漏。
	if [[ "$got" == "400" || "$got" == "403" || "$got" == "404" ]]; then
		printf '  \033[32mok\033[0m   %-34s %s (%s)\n' "$desc" "$raw" "$got"
	else
		printf '  \033[31mFAIL\033[0m %-34s %s (期望 400/403/404 实际 %s)\n' "$desc" "$raw" "$got"
		fail=1
	fi
}
traverse "明文穿越被挡"            "/../../../etc/passwd"
traverse "编码穿越被挡"            "/..%2f..%2f..%2fetc%2fpasswd"
traverse "混合编码穿越被挡"        "/%2e%2e/%2e%2e/%2e%2e/etc/passwd"
traverse "绝对路径逃逸被挡"        "//etc/passwd"

# 只允许 GET/HEAD
code="$(curl -s -o /dev/null -w '%{http_code}' -X DELETE "$BASE/")"
if [[ "$code" == "403" ]]; then
	printf '  \033[32mok\033[0m   %-34s %s\n' "DELETE 被拒" "403"
else
	printf '  \033[31mFAIL\033[0m %-34s %s (实际 %s)\n' "DELETE 被拒" "$code"
	fail=1
fi

# 缓存策略：HTML 必须每次回源校验，只有带哈希的产物才 immutable。
# 这条踩过坑：HTML 被缓存 10 分钟时，页面里引用的是旧哈希的 CSS/JS，
# 于是「服务端已经更新、页面却刷不出来」，从浏览器侧完全看不出原因。
cache_of() { curl -s -D - -o /dev/null --max-time 10 "$1" | grep -i '^cache-control' | tr -d '\r' | sed 's/^[Cc]ache-[Cc]ontrol: *//'; }
for p in / /graphrag/ /graphrag/nano-graphrag-tutorial.html /graphrag/nano-graphrag-source-analysis.html; do
	cc="$(cache_of "${BASE}${p}")"
	if [[ "$cc" == no-store* ]]; then
		printf '  \033[32mok\033[0m   %-34s %s\n' "HTML 不存储 ${p}" "$cc"
	else
		printf '  \033[31mFAIL\033[0m %-34s %s (HTML 必须 no-store)\n' "HTML 不存储 ${p}" "$cc"
		fail=1
	fi
done
asset="$(curl -s "${BASE}/" | grep -o '/assets/style\.[A-Za-z0-9_-]*\.css' | head -1)"
if [[ -n "$asset" ]]; then
	cc="$(cache_of "${BASE}${asset}")"
	if [[ "$cc" == *immutable* ]]; then
		printf '  \033[32mok\033[0m   %-34s %s\n' "带哈希产物 immutable" "$cc"
	else
		printf '  \033[31mFAIL\033[0m %-34s %s (应为 immutable)\n' "带哈希产物 immutable" "$cc"
		fail=1
	fi
fi

# HTTP 必须 301 到 HTTPS（否则用户第一次访问是明文，HSTS 也就无从谈起）
redir="$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' --max-time 10 \
	--resolve "${SITE_DOMAIN}:80:127.0.0.1" "http://${SITE_DOMAIN}/graphrag/" || echo "000 ")"
if [[ "$redir" == 301* && "$redir" == *https://* ]]; then
	printf '  \033[32mok\033[0m   %-34s %s\n' "HTTP→HTTPS 跳转" "$redir"
else
	printf '  \033[31mFAIL\033[0m %-34s %s\n' "HTTP 未跳 HTTPS" "$redir"
	fail=1
fi

# www 也要能到，且规范到主域
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
	--resolve "${SITE_DOMAIN_ALT}:${LISTEN_PORT}:127.0.0.1" "https://${SITE_DOMAIN_ALT}/")"
if [[ "$code" == "200" ]]; then
	printf '  \033[32mok\033[0m   %-34s %s\n' "www 域名可访问" "$code"
else
	printf '  \033[31mFAIL\033[0m %-34s %s\n' "www 域名" "$code"
	fail=1
fi

# 用真实 IP + 裸 Host 访问 443，应该被拒（没有匹配的 server_name 就走
# 第一个 443 块，也就是本站）—— 这条主要防证书被裸 IP 意外复用
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -k \
	"https://127.0.0.1/" 2>/dev/null || echo 000)"
printf '  \033[90minfo\033[0m %-34s %s\n' "裸 IP 访问 443" "$code"

# 安全头是否真的发出来了
log "检查安全响应头"
hdrs="$("${CURL[@]}" -D - -o /dev/null "$BASE/")"
for h in strict-transport-security content-security-policy x-content-type-options x-frame-options referrer-policy permissions-policy; do
	if grep -qi "^$h:" <<<"$hdrs"; then
		printf '  \033[32mok\033[0m   %s\n' "$h"
	else
		printf '  \033[31mFAIL\033[0m %s 缺失\n' "$h"
		fail=1
	fi
done
if grep -qi '^server: nginx/[0-9]' <<<"$hdrs"; then
	printf '  \033[31mFAIL\033[0m Server 头泄露了版本号\n'
	fail=1
else
	printf '  \033[32mok\033[0m   Server 头未泄露版本号\n'
fi

log "检查 TLS"
if echo | timeout 10 openssl s_client -connect "127.0.0.1:${LISTEN_PORT}" \
	-servername "$SITE_DOMAIN" 2>/dev/null | grep -q "TLSv1.3"; then
	printf '  \033[32mok\033[0m   TLS 1.3 可用\n'
else
	printf '  \033[31mFAIL\033[0m TLS 1.3 不可用\n'
	fail=1
fi

# 确认服务端确实拒绝 TLS 1.0/1.1。
# 必须加 -cipher DEFAULT@SECLEVEL=0：Debian 的 openssl 客户端默认自己就不发
# TLS1.1，不降级别的话测的是「客户端不发」而不是「服务端拒绝」，会拿到假通过。
legacy_rejected=1
for v in tls1 tls1_1; do
	if echo | timeout 10 openssl s_client -connect "127.0.0.1:${LISTEN_PORT}" \
		-servername "$SITE_DOMAIN" "-$v" -cipher 'DEFAULT@SECLEVEL=0' 2>&1 \
		| grep -qE "^New, TLS|^Cipher    :"; then
		printf '  \033[31mFAIL\033[0m %-34s %s\n' "TLS 1.0/1.1 已被拒绝" "$v 居然能握手"
		legacy_rejected=0
	fi
done
if [[ $legacy_rejected -eq 1 ]]; then
	printf '  \033[32mok\033[0m   %-34s %s\n' "TLS 1.0/1.1 已被拒绝" "alert protocol version"
fi

log "检查 CSP 是否真的覆盖了所有内联脚本"
# 重新从运行中的站点取 CSP 头重算一遍，防止哈希算错导致脚本被浏览器静默拦掉
XMQX_CURL_RESOLVE="${SITE_DOMAIN}:${LISTEN_PORT}:127.0.0.1" \
	python3 "$VERIFY_CSP" "$BASE" "$DIST_DIR" || die "CSP 复核未通过"

[[ $fail -eq 0 ]] || die "冒烟测试未通过"

# 手动部署成功时也把 auto-deploy 的状态同步掉，否则它下次还会把同一个提交
# 当成「待部署」白构建一遍。
STATE_DIR="$REPO_DIR/.deploy-state"
if [[ -d "$STATE_DIR" ]] && git -C "$REPO_DIR" rev-parse --git-dir >/dev/null 2>&1; then
	git -C "$REPO_DIR" rev-parse HEAD > "$STATE_DIR/last-good-sha"
	date -Is | { read -r ts; printf '%s 成功 %s\n' "$ts" "$(git -C "$REPO_DIR" rev-parse HEAD)"; } > "$STATE_DIR/last-result"
fi

log "部署完成"
printf '    公网:      https://%s/\n' "$SITE_DOMAIN"
printf '    www:       https://%s/  （同一张证书）\n' "$SITE_DOMAIN_ALT"
printf '    本机测试:  curl -H "Host: %s" http://127.0.0.1/\n' "$SITE_DOMAIN"
if ! ss -ltn 2>/dev/null | grep -q ":${LISTEN_PORT}[[:space:]]"; then
	warn "本机 ${LISTEN_PORT} 没在监听，请检查 nginx"
fi
# 从外部能不能连上，取决于安全组，跟 nginx 配置无关，这里提前说清楚，
# 免得部署完了访问不了以为是站点挂了。
PUBLIC_IP="$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || echo '')"
if [[ -n "$PUBLIC_IP" ]] && ! timeout 6 bash -c "echo > /dev/tcp/${PUBLIC_IP}/${LISTEN_PORT}" 2>/dev/null; then
	warn "公网 ${PUBLIC_IP}:${LISTEN_PORT} 连不上 —— 需要在 AWS 安全组放行入站 TCP ${LISTEN_PORT}"
	warn "（80 目前是放行的，所以证书续签不受影响）"
fi
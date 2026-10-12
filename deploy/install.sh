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
LISTEN_PORT="8081"
SITE_AVAILABLE="/etc/nginx/sites-available/$SITE_NAME"
SITE_ENABLED="/etc/nginx/sites-enabled/$SITE_NAME"
LIMITS_CONF="/etc/nginx/conf.d/${SITE_NAME}-limits.conf"

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
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
	die "已有另一个部署在进行中（锁文件 $LOCK_FILE）"
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

# nginx 以 www-data 运行，必须能从站点目录一路穿过去；缺哪一环就点出来
log "检查 nginx(www-data) 能否读取产物"
bad=""
for p in /home/admin "$REPO_DIR" "$REPO_DIR/docs" "$REPO_DIR/docs/.vitepress" "$DIST_DIR"; do
	[[ -x "$p" ]] || bad+=" 缺 traverse: $p\n"
done
if [[ -n "$bad" ]] || ! sudo -u www-data test -r "$DIST_DIR/index.html"; then
	warn "www-data 读不到产物："
	[[ -n "$bad" ]] && printf "%b" "$bad"
	die "请修正权限，例如： sudo chmod o+x /home/admin && chmod -R o+rX $DIST_DIR"
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
BASE="http://127.0.0.1:${LISTEN_PORT}"
fail=0
check() { # check <期望状态> <描述> <路径>
	local want="$1" desc="$2" path="$3" got
	got="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$BASE$path" || echo 000)"
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
	got="$(curl -s -o /dev/null -w '%{http_code}' --path-as-is --max-time 10 "$BASE$raw" || echo 000)"
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
code="$(curl -s -o /dev/null -w '%{http_code}' -X DELETE --max-time 10 "$BASE/")"
if [[ "$code" == "403" ]]; then
	printf '  \033[32mok\033[0m   %-34s %s\n' "DELETE 被拒" "403"
else
	printf '  \033[31mFAIL\033[0m %-34s %s (实际 %s)\n' "DELETE 被拒" "$code"
	fail=1
fi

# 安全头是否真的发出来了
log "检查安全响应头"
hdrs="$(curl -s -D - -o /dev/null --max-time 10 "$BASE/")"
for h in content-security-policy x-content-type-options x-frame-options referrer-policy permissions-policy; do
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

log "检查 CSP 是否真的覆盖了所有内联脚本"
# 重新从运行中的站点取 CSP 头重算一遍，防止哈希算错导致脚本被浏览器静默拦掉
python3 "$VERIFY_CSP" "http://127.0.0.1:${LISTEN_PORT}" "$DIST_DIR" || die "CSP 复核未通过"

[[ $fail -eq 0 ]] || die "冒烟测试未通过"

log "部署完成"
printf '    本机:      %s\n' "$BASE"
printf '    局域网:    http://%s:%s/\n' "$(hostname -I | awk '{print $1}')" "$LISTEN_PORT"
printf '    公网:      http://54.206.104.234:%s/  （需在 AWS 安全组放行 TCP %s）\n' "$LISTEN_PORT" "$LISTEN_PORT"
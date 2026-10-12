#!/usr/bin/env bash
# XMQX-blog 自动部署：拉取仓库最新提交 → 重新构建 → 重载 nginx。
#
#   deploy/auto-deploy.sh              # 检查一次，有新提交就部署
#   deploy/auto-deploy.sh --status     # 只看状态，不做任何改动
#   deploy/auto-deploy.sh --force      # 不管有没有新提交都重新部署一遍
#
# 由 xmqx-blog-deploy.timer 每 2 分钟调一次。也可以手动跑。
#
# 设计要点：
#   * 没有新提交就秒退，不打扰线上（timer 每 2 分钟跑一次，不能每次都 build）。
#   * 只接受 fast-forward 更新：`--ff-only`。远端被塞一个 merge commit 时
#     直接拒绝，而不是在服务器上自动生成一个 merge。
#   * 工作区不干净就拒绝部署。不动你本地的未提交修改。
#   * 部署失败自动回滚到上一个「已知可用」的提交并重新构建。
#     注意回滚用的是那个提交自己的 deploy/install.sh —— 如果坏掉的正是
#     install.sh 本身，那 `git reset --hard` 已经把它一起换回去了，
#     所以回滚路径不会踩到同一个坑。
#   * 全程 flock，和手动 install.sh 互斥，不会两边同时改 dist。

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="$REPO_DIR/deploy/install.sh"
STATE_DIR="$REPO_DIR/.deploy-state"
LAST_GOOD="$STATE_DIR/last-good-sha"
LAST_RESULT="$STATE_DIR/last-result"
BRANCH="${XMQX_BRANCH:-main}"
REMOTE="${XMQX_REMOTE:-origin}"
# 两次成功部署之间的最小间隔，防止有人连着推 10 个 commit 时被 build 10 次
MIN_INTERVAL="${XMQX_MIN_INTERVAL:-120}"

FORCE=0
STATUS_ONLY=0
case "${1:-}" in
	--status) STATUS_ONLY=1 ;;
	--force)  FORCE=1 ;;
esac

cd "$REPO_DIR"
mkdir -p "$STATE_DIR"

log()  { printf '%s [auto-deploy] %s\n' "$(date -Is)" "$*"; }
die()  { printf '%s [auto-deploy] 错误: %s\n' "$(date -Is)" "$*" >&2; exit 1; }

sha_of() { git rev-parse --verify --quiet "$1" 2>/dev/null || echo ""; }

# 读状态文件。set -o pipefail 下 `cat 不存在的文件 | cut` 会让整条管道返回 1，
# 再叠加 set -e 脚本就直接静默退出了（第一次跑还没状态文件，必踩）。
read_state() {
	local f
	case "$1" in
		LAST_GOOD)  f="$LAST_GOOD" ;;
		LAST_RESULT) f="$LAST_RESULT" ;;
		*) die "read_state: 未知的状态键 $1" ;;
	esac
	[[ -r "$f" ]] || { echo "<无>"; return 0; }
	cat "$f"
}

status() {
	local head remote deployed
	head="$(git rev-parse --short HEAD 2>/dev/null || echo '?')"
	remote="$(sha_of "$REMOTE/$BRANCH" | cut -c1-7)"
	deployed="$(read_state LAST_GOOD | cut -c1-7)"
	printf '分支          %s (%s)\n' "$BRANCH" "$REMOTE"
	printf '工作区 HEAD   %s\n' "$head"
	printf '远端 %s   %s\n' "$REMOTE/$BRANCH" "${remote:-<未 fetch>}"
	printf '已部署提交    %s\n' "${deployed:-<从未成功部署>}"
	printf '上次结果      %s\n' "$(read_state LAST_RESULT)"
	local timer_state
	timer_state="$(systemctl is-enabled xmqx-blog-deploy.timer 2>/dev/null || true)"
	printf '定时器        %s / %s\n' \
		"$(systemctl is-active xmqx-blog-deploy.timer 2>/dev/null || echo unknown)" \
		"${timer_state:-未安装}"
	printf '证书到期      %s (%s)\n' \
		"$(sudo -n openssl x509 -in /etc/letsencrypt/live/xmqx.online/fullchain.pem \
			-noout -enddate 2>/dev/null | cut -d= -f2 || echo '未知')" \
		"$(systemctl is-active certbot.timer 2>/dev/null || echo 'certbot.timer 未运行')"
	printf '站点          %s / http 跳转 %s\n' \
		"$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 https://xmqx.online/ 2>/dev/null || echo '无响应')" \
		"$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://xmqx.online/ 2>/dev/null || echo '无响应')"
}

[[ "$STATUS_ONLY" == "1" ]] && { status; exit 0; }

# ---------------------------------------------------------------- 拉取
# fetch 用短超时：网络抽风时快速失败，别占着 timer 的执行窗口。
log "fetch $REMOTE/$BRANCH"
if ! timeout 60 git fetch --quiet --prune "$REMOTE" "$BRANCH"; then
	die "fetch 失败（网络问题？），本次不部署"
fi

target="$(sha_of "$REMOTE/$BRANCH")"
[[ -n "$target" ]] || die "远端分支 $REMOTE/$BRANCH 不存在"

last_good="$(read_state LAST_GOOD)"
[[ "$last_good" == "<无>" ]] && last_good=""

if [[ $FORCE -eq 0 && "$target" == "$last_good" ]]; then
	log "无新提交（$target），跳过"
	exit 0
fi

# 工作区脏了就停手：自动 reset 会吃掉你本地的未提交修改
if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
	die "工作区有未提交修改，拒绝自动部署。请先 commit 或 stash。"
fi

# 只接受快进。远端出现 merge commit、或被 force-push/rebase 改写了历史时直接拒绝，
# 免得服务器上凭空多出一个 merge，或者把本地已部署的历史悄悄改掉。
# 故意不给 --allow-unrelated-histories：两边已经分叉是需要人来看的事，不该自动和解。
if ! git merge --ff-only --quiet "$REMOTE/$BRANCH"; then
	die "无法快进到 $REMOTE/$BRANCH（远端可能发生了 rebase/force-push），需人工介入"
fi

head_now="$(git rev-parse HEAD)"

# 判断依据是「合并之后的 HEAD 是不是已经部署过了」，而不是「远端有没有变」。
# 用后者会在本地领先远端时（部署脚本还没推上 GitHub 时就是这个状态）
# 每轮都判定成「有更新」，于是每 2 分钟白白重建 + 重载一次 nginx。
if [[ $FORCE -eq 0 && "$head_now" == "$last_good" ]]; then
	log "远端无实质更新（本地 $head_now 就是线上版本），跳过"
	exit 0
fi

log "更新 ${last_good:-<无>} -> $head_now"

# 节流：连续推送时不反复 build
if [[ -n "$last_good" ]] && [[ $FORCE -eq 0 ]]; then
	last_ts="$(stat -c %Y "$LAST_GOOD" 2>/dev/null || echo 0)"
	now_ts="$(date +%s)"
	if (( now_ts - last_ts < MIN_INTERVAL )); then
		log "距上次部署不足 ${MIN_INTERVAL}s，本次跳过"
		exit 0
	fi
fi

# ---------------------------------------------------------------- 部署
if bash "$INSTALL_SH"; then
	echo "$head_now" > "$LAST_GOOD"
	echo "$(date -Is) 成功 $head_now" > "$LAST_RESULT"
	log "部署成功 $head_now"
	exit 0
fi

# ---------------------------------------------------------------- 回滚
warn_msg="部署失败，正在回滚"
printf '%s [auto-deploy] %s\n' "$(date -Is)" "$warn_msg" >&2

if [[ -z "$last_good" ]]; then
	echo "$(date -Is) 失败(无回滚点) $head_now" > "$LAST_RESULT"
	die "首次部署就失败，没有可回滚的提交。线上保持原样，请手动排查。"
fi

log "回滚到 $last_good"
# reset --hard 会无声吞掉未提交的修改。开跑时检查过一次工作区是干净的，
# 但构建这几十秒里完全可能有人动了文件，所以动手前再确认一次。
if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
	# 有改动就不能 reset：宁可让站点停在坏版本，也不要替用户删掉他正在写的东西。
	# 把改动挪到 stash 里，人工恢复（git stash pop）。
	git stash push --quiet --message "auto-deploy: 回滚被中止，$(date -Is) 期间产生的改动" || true
	echo "$(date -Is) 失败(回滚中止,改动已 stash) $head_now" > "$LAST_RESULT"
	die "回滚期间工作区出现新改动，已 stash 保护起来，需人工处理。站点停在 $head_now（构建失败的状态）。"
fi

git reset --hard --quiet "$last_good"

if bash "$INSTALL_SH"; then
	echo "$(date -Is) 失败后已回滚到 $last_good（问题提交 $head_now）" > "$LAST_RESULT"
	die "已回滚到 $last_good，线上恢复正常。问题提交 $head_now 见 journal。"
fi

echo "$(date -Is) 失败且回滚也失败 (坏提交 $head_now)" > "$LAST_RESULT"
die "回滚也失败，线上可能不可用，需立即人工介入！"
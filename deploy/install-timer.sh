#!/usr/bin/env bash
# 安装 / 卸载 XMQX-blog 的自动部署 systemd 单元。
#
#   sudo ./deploy/install-timer.sh            # 安装并启动定时器
#   sudo ./deploy/install-timer.sh --uninstall # 停掉并移除
#   sudo ./deploy/install-timer.sh --status    # 只看状态

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPLOY_DIR="$REPO_DIR/deploy"
UNIT_DIR="/etc/systemd/system"

SERVICE_UNIT="$UNIT_DIR/xmqx-blog-deploy.service"
TIMER_UNIT="$UNIT_DIR/xmqx-blog-deploy.timer"

log() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "请用 sudo 执行：sudo ./deploy/install-timer.sh"

do_status() {
	systemctl is-enabled xmqx-blog-deploy.timer 2>/dev/null | sed 's/^/  timer enabled:  /'
	systemctl is-active xmqx-blog-deploy.timer 2>/dev/null | sed 's/^/  timer active:   /'
	systemctl list-timers xmqx-blog-deploy.timer --no-pager 2>/dev/null || true
	echo
	"$DEPLOY_DIR/auto-deploy.sh" --status
}

do_uninstall() {
	log "停用并移除定时器"
	systemctl disable --now xmqx-blog-deploy.timer 2>/dev/null || true
	rm -f "$SERVICE_UNIT" "$TIMER_UNIT"
	systemctl daemon-reload
	systemctl reset-failed xmqx-blog-deploy.service 2>/dev/null || true
	log "已移除。站点仍在跑（由 deploy/install.sh 部署的 nginx 配置提供），只是不再自动更新。"
}

do_install() {
	[[ -x "$DEPLOY_DIR/auto-deploy.sh" ]] || die "$DEPLOY_DIR/auto-deploy.sh 不可执行"
	[[ -f "$DEPLOY_DIR/install.sh" ]]      || die "缺少 $DEPLOY_DIR/install.sh"
	[[ -d "$REPO_DIR/.git" ]]              || die "$REPO_DIR 不是 git 仓库"

	# 无密码 sudo 是 install.sh 写 /etc/nginx 的前提，这里先探一下，
	# 免得装完第一次跑才报错
	sudo -n true 2>/dev/null || die "当前用户没有免密 sudo，install.sh 会失败"

	log "安装 systemd 单元"
	install -m 0644 "$DEPLOY_DIR/xmqx-blog-deploy.service" "$SERVICE_UNIT"
	install -m 0644 "$DEPLOY_DIR/xmqx-blog-deploy.timer"   "$TIMER_UNIT"
	systemctl daemon-reload

	log "启动定时器"
	systemctl enable --now xmqx-blog-deploy.timer

	log "立即跑一次，验证链路通不通"
	if systemctl start --no-block xmqx-blog-deploy.service; then
		sleep 3
	fi
	sleep 1
	systemctl status xmqx-blog-deploy.service --no-pager -n 20 || true

	do_status
}

case "${1:-}" in
	--uninstall) do_uninstall ;;
	--status)    do_status ;;
	*)           do_install ;;
esac
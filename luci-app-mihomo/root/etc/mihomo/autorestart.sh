#!/bin/sh
# 定时重启 mihomo 服务。
#
# 长时间运行的代理进程会积累连接状态与内存碎片, 部分用户习惯在低峰时段
# (如每天凌晨) 重启一次服务。本脚本按 uci 里的设置把这条重启命令写进
# crontab, 并在关闭时把托管块移除。除此之外它不做任何事。
#
#   autorestart.sh apply               读取 uci mihomo.autorestart, 写入 crontab 并生效
#   autorestart.sh set <enabled> [schedule]
#                                      用给定值写 uci 再生效 (LuCI 页面用这条)
#   autorestart.sh remove              移除本脚本管理的计划任务
#   autorestart.sh status              打印当前状态 (供页面显示)
#
# set 为什么不用 rpcd 的 uci.apply: 通过 ubus 提交 UCI 会走 /sbin/reload_config,
# 它比对 /etc/config/* 的内容变化并发 config.change 事件, 使注册了
# procd_add_reload_trigger 的服务执行 reload —— mihomo 的 reload_service 是
# stop + start, 也就是说只改一个定时设置就会把代理重启一次。命令行 uci 不会发
# 这个事件, 所以由本脚本自己 uci set / uci commit。与 autoupdate.sh 相同。
#
# 只管理带标记的块, 用户自己写的计划任务不受影响:
#
#   # mihomo-restart begin -- managed by luci-app-mihomo, do not edit
#   <schedule> /etc/init.d/mihomo restart 2>&1 | logger -t mihomo-restart
#   # mihomo-restart end
#
# 之所以用 cron 而不是常驻循环: crond 由 busybox 提供, 不需要额外软件包;
# 任务同时能在 LuCI 的「系统 → 计划任务」里看到。
#
# 注意 /etc/init.d/cron 在 /etc/crontabs/ 为空时 start_service 会直接返回 1
# (package/utils/busybox/files/cron: [ -z "$(ls /etc/crontabs/)" ] && return 1),
# 所以移除任务后 crond 会自然停掉, 这是预期行为, 不是错误。

[ -s /lib/functions.sh ] && . /lib/functions.sh

CRONTAB="/etc/crontabs/root"
CRON_INIT="/etc/init.d/cron"
RC_CRON_GLOB="/etc/rc.d/S*cron"
INIT_SERVICE="/etc/init.d/mihomo"
BEGIN="# mihomo-restart begin -- managed by luci-app-mihomo, do not edit"
END="# mihomo-restart end"
LOG_TAG="mihomo-restart"
DEFAULT_SCHEDULE="0 4 * * *"

die() {
	echo "错误: $*" >&2
	exit 1
}

# ---- 参数校验 (这个值最终会出现在 crontab 里由 shell 执行, 必须严格) ----

# cron 时间字段: 只允许 0-9 * / , - 与空格, 且必须 5 段。
# 页面上的 validSchedule() 用同一条规则 (/^[0-9*/, -]+$/ + 5 段) 先行拦一次。
validate_schedule() {
	local sched="$1"

	printf '%s' "$sched" | grep -qE '^[0-9*/, -]+$' \
		|| die "非法的执行时间 '$sched' (只允许 0-9 空格 * / , -)"

	# 数段数必须临时关掉通配展开: 值里几乎一定含 '*', 而 "$sched" 一旦不加引号
	# 就会被当成通配符展开成当前目录下的文件名 (段数于是变成几十上百, 校验必然失败)。
	set -f
	# shellcheck disable=SC2086
	set -- $sched
	set +f

	[ $# -eq 5 ] || die "非法的执行时间 '$sched' (需要 5 段: 分 时 日 月 周)"
}

# ---- crontab 读写 (只动托管块) ----

strip_block() {
	[ -f "$CRONTAB" ] || return 0

	awk -v b="$BEGIN" -v e="$END" '
		$0 == b { skip = 1; next }
		$0 == e { skip = 0; next }
		!skip   { print }
	' "$CRONTAB"
}

write_crontab() {
	# $1 = 托管块里的那行命令; 空字符串表示不写块
	local t="$CRONTAB.$$" line="$1"

	mkdir -p "$(dirname "$CRONTAB")" || die "无法创建 $(dirname "$CRONTAB")"

	strip_block > "$t" || { rm -f "$t"; die "读取 $CRONTAB 失败"; }

	if [ -n "$line" ]; then
		[ -s "$t" ] && printf '\n' >> "$t"
		{
			printf '%s\n' "$BEGIN"
			printf '%s\n' "$line"
			printf '%s\n' "$END"
		} >> "$t"
	fi

	chmod 600 "$t"
	mv -f "$t" "$CRONTAB" || { rm -f "$t"; die "替换 $CRONTAB 失败"; }
}

cron_reload() {
	[ -x "$CRON_INIT" ] || die "系统里没有 cron 服务 ($CRON_INIT), 无法启用定时重启"

	if [ -s "$CRONTAB" ]; then
		"$CRON_INIT" enable >/dev/null 2>&1
		"$CRON_INIT" restart
	else
		# crontab 为空: crond 会自行退出, 这里不再 enable
		"$CRON_INIT" restart
	fi
}

managed_line() {
	[ -f "$CRONTAB" ] || return 0

	awk -v b="$BEGIN" -v e="$END" '
		$0 == b { inblk = 1; next }
		$0 == e { inblk = 0; next }
		inblk && !/^#/ { print }
	' "$CRONTAB"
}

# ---- uci 读写 (命令行 uci, 不经过 ubus, 因此不会触发服务 reload) ----

uci_save_settings() {
	# $1=enabled $2=schedule
	local enabled="$1" schedule="$2"

	command -v uci >/dev/null 2>&1 || die "系统里没有 uci 命令, 无法保存定时重启设置"

	# 段不存在时先建出来, 这样 uci show 里能看到它, 也知道类型
	uci -q get "mihomo.autorestart" >/dev/null 2>&1 \
		|| uci -q set "mihomo.autorestart=autorestart" >/dev/null 2>&1 \
		|| die "无法创建 uci 段 mihomo.autorestart"

	uci -q set "mihomo.autorestart.enabled=$enabled"

	if [ -n "$schedule" ]; then
		uci -q set "mihomo.autorestart.schedule=$schedule"
	else
		uci -q delete "mihomo.autorestart.schedule" 2>/dev/null
	fi

	uci -q commit mihomo || die "写入 /etc/config/mihomo 失败"
}

# ---- 命令 ----

do_set() {
	local enabled="$1" schedule="$2"

	case "$enabled" in
		1) enabled=1 ;;
		*) enabled=0 ;;
	esac

	if [ "$enabled" = "1" ]; then
		[ -n "$schedule" ] || schedule="$DEFAULT_SCHEDULE"
		validate_schedule "$schedule"
	else
		[ -n "$schedule" ] && validate_schedule "$schedule"
	fi

	uci_save_settings "$enabled" "$schedule"

	# 写完 uci 立刻生效 (apply 自己会读回刚写的值)
	do_apply
}

do_apply() {
	local enabled schedule line

	config_load mihomo
	config_get enabled  "autorestart" "enabled"  "0"
	config_get schedule "autorestart" "schedule" "$DEFAULT_SCHEDULE"

	[ -n "$schedule" ] || schedule="$DEFAULT_SCHEDULE"

	if [ "$enabled" != "1" ]; then
		do_remove
		echo "定时重启已关闭, 计划任务已移除"
		return 0
	fi

	validate_schedule "$schedule"

	line="$schedule $INIT_SERVICE restart 2>&1 | logger -t $LOG_TAG"

	write_crontab "$line"
	cron_reload

	echo "定时重启已启用"
	echo "执行时间: $schedule"
	echo "计划任务: $line"
	echo "重启结果会写入系统日志 (logger -t $LOG_TAG)。"
}

do_remove() {
	write_crontab ""
	cron_reload

	echo "计划任务已移除"
}

do_status() {
	local enabled schedule line

	config_load mihomo
	config_get enabled  "autorestart" "enabled"  "0"
	config_get schedule "autorestart" "schedule" "$DEFAULT_SCHEDULE"

	line="$(managed_line)"

	if [ "$enabled" = "1" ]; then
		echo "定时重启: 已启用"
	else
		echo "定时重启: 未启用"
	fi

	echo "执行时间: ${schedule:-（未设置）}"

	if ls $RC_CRON_GLOB >/dev/null 2>&1; then
		echo "cron 服务: 已设置为开机启用"
	else
		echo "cron 服务: 未设置开机启用"
	fi

	if "$CRON_INIT" running >/dev/null 2>&1; then
		echo "cron 进程: 运行中"
	else
		echo "cron 进程: 未运行"
	fi

	if [ -n "$line" ]; then
		echo "计划任务: $line"
	else
		echo "计划任务: （无）"
	fi
}

cmd="$1"
[ $# -gt 0 ] && shift

case "$cmd" in
	apply)
		do_apply
		;;
	set)
		do_set "$1" "$2"
		;;
	remove)
		do_remove
		;;
	status)
		do_status
		;;
	help|-h|--help|"")
		cat <<EOF
Usage: $0 apply | set <enabled> [schedule] | remove | status

  apply   读 uci mihomo.autorestart 并把计划任务写入 $CRONTAB
  set     用给定值写 uci mihomo.autorestart 随后生效 (LuCI 页面用这条)
          enabled  1/0
          schedule cron 时间字段 (5 段), 关闭时可以留空; 启用时留空用默认 $DEFAULT_SCHEDULE
  remove  移除定时重启写入的计划任务
  status  打印当前状态
EOF
		;;
	*)
		echo "未知命令: $cmd" >&2
		exit 1
		;;
esac

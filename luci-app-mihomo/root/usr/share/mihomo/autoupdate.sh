#!/bin/bash
# 定时更新 mihomo 的「服务器与代理组」。
#
# 实际动作全部交给 config.sh update: 它只替换 proxies / proxy-groups 两段, 并且
# 在远程内容与本地一致时什么都不做; 只有内容确实变了才写盘并重启 mihomo。本脚本
# 只负责把这条命令按 uci 里的设置写进 crontab, 并在关闭时把托管块移除。
#
#   autoupdate.sh apply    读取 uci mihomo.autoupdate, 写入 /etc/crontabs/root 并生效
#   autoupdate.sh set <enabled> <target> <schedule>
#                          用给定值写 uci 再生效 (LuCI 页面用这条)
#   autoupdate.sh remove   移除本脚本管理的计划任务
#   autoupdate.sh status   打印当前状态 (供页面显示)
#
# ★ 订阅链接不落在 uci 里, 也不进 cron 命令行。计划任务只记「更新哪个文件」,
#   链接由 config.sh update 在运行时按文件名去 <workdir>/sources 查。
#   原因: 早先把链接快照进 uci 后, 换目标配置不会同步换链接 —— cron 会一直拿
#   上一个配置的链接去更新新目标, 配置文件与其来源就此脱钩。sources 是导入
#   订阅时记录的唯一事实源, 一处记录, 手动「仅更新」与定时任务共用。
#
# set 为什么不用 rpcd 的 uci.apply: 通过 ubus 提交 UCI 会走 /sbin/reload_config,
# 它比对 /etc/config/* 的内容变化并发 config.change 事件, 使注册了
# procd_add_reload_trigger 的服务执行 reload —— mihomo 的 reload_service 是
# stop + start, 也就是说只改一个定时设置就会把代理重启一次。命令行 uci 不会发
# 这个事件, 所以由本脚本自己 uci set / uci commit。
#
# 只管理带标记的块, 用户自己写的计划任务不受影响:
#
#   # mihomo-autoupdate begin -- managed by luci-app-mihomo, do not edit
#   <schedule> PATH=... /usr/share/mihomo/config.sh update '<target>' 2>&1 | logger -t mihomo-autoupdate
#   # mihomo-autoupdate end
#
# 之所以用 cron 而不是常驻循环: crond 由 busybox 提供 (package/utils/busybox
# 的 files/cron), 不需要额外软件包, 也不会有常驻进程; 任务同时能在 LuCI 的
# 「系统 → 计划任务」里看到。
#
# 注意 /etc/init.d/cron 在 /etc/crontabs/ 为空时 start_service 会直接返回 1
# (package/utils/busybox/files/cron: [ -z "$(ls /etc/crontabs/)" ] && return 1),
# 所以移除任务后 crond 会自然停掉, 这是预期行为, 不是错误。
# 该 init 脚本用 procd (USE_PROCD=1), 因此 running / enabled 子命令都可用。
#
# 更新失败的原因由 config.sh 打印, 经 logger 进系统日志 (logread / LuCI「系统日志」)。

[ -s /lib/functions.sh ] && . /lib/functions.sh

CRONTAB="/etc/crontabs/root"
HELPER="/usr/share/mihomo/config.sh"
BEGIN="# mihomo-autoupdate begin -- managed by luci-app-mihomo, do not edit"
END="# mihomo-autoupdate end"
CRON_PATH="/usr/bin:/bin:/usr/sbin:/sbin"
LOG_TAG="mihomo-autoupdate"
# 铁律: 定时任务不写整点, 分钟取非 0 (17)。
DEFAULT_SCHEDULE="17 4 * * *"

die() {
	echo "错误: $*" >&2
	exit 1
}

load_config() {
	WORKDIR="/etc/mihomo"

	config_load mihomo
	config_get WORKDIR "main" "workdir" "/etc/mihomo"
}

# 该配置记录的订阅链接 (导入订阅 / 手动「仅更新」成功时由 config.sh 写入
# <workdir>/sources, 每行 "<文件名> <url>")。
# 格式与 config.sh 的 source_get 完全一致 —— 这里是同一份事实源的另一个读者,
# 任何一处改格式都必须同时改两处。
source_get() {
	local f="$WORKDIR/sources"

	[ -f "$f" ] || return 0

	awk -v n="$1" '$1 == n { sub(/^[^[:space:]]+[[:space:]]+/, ""); print; exit }' "$f" 2>/dev/null
}

# ---- 参数校验 (这些值最终会出现在 crontab 里由 shell 执行, 必须严格) ----

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

# 单引号包裹的值: 只要不含单引号就不会破坏 crontab 结构 (单引号内不做展开)
validate_arg() {
	case "$1" in
		*"'"*) die "参数里不允许单引号: $1" ;;
	esac

	[ "$(printf '%s' "$1" | wc -l)" -eq 0 ] || die "参数里不允许换行"
}

validate_target() {
	case "$1" in
		*/*|*\\*|.|..|.*) die "非法目标配置名 '$1' (不允许路径与隐藏文件)" ;;
	esac
	case "$1" in
		*[!A-Za-z0-9._-]*) die "非法目标配置名 '$1' (只允许 A-Za-z0-9 . _ - )" ;;
	esac
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
	[ -x /etc/init.d/cron ] || die "系统里没有 cron 服务 (/etc/init.d/cron), 无法启用定时更新"

	if [ -s "$CRONTAB" ]; then
		/etc/init.d/cron enable >/dev/null 2>&1
		/etc/init.d/cron restart
	else
		# crontab 为空: crond 会自行退出, 这里不再 enable
		/etc/init.d/cron restart
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
	# $1=enabled $2=target $3=schedule
	local enabled="$1" target="$2" schedule="$3"

	command -v uci >/dev/null 2>&1 || die "系统里没有 uci 命令, 无法保存定时设置"

	# 段不存在时先建出来, 这样 uci show 里能看到它, 也知道类型
	uci -q get "mihomo.autoupdate" >/dev/null 2>&1 \
		|| uci -q set "mihomo.autoupdate=autoupdate" >/dev/null 2>&1 \
		|| die "无法创建 uci 段 mihomo.autoupdate"

	uci -q set "mihomo.autoupdate.enabled=$enabled"

	if [ -n "$target" ]; then
		uci -q set "mihomo.autoupdate.target=$target"
	else
		uci -q delete "mihomo.autoupdate.target" 2>/dev/null
	fi

	if [ -n "$schedule" ]; then
		uci -q set "mihomo.autoupdate.schedule=$schedule"
	else
		uci -q delete "mihomo.autoupdate.schedule" 2>/dev/null
	fi

	# 旧版本把订阅链接快照在 mihomo.autoupdate.url 里, 那是「配置与来源脱钩」的
	# 根源 (换目标不换链接)。现在链接只在 <workdir>/sources 里有一份, 这里顺手
	# 把这个历史键删掉, 免得残留值继续误导人。
	uci -q delete "mihomo.autoupdate.url" 2>/dev/null

	uci -q commit mihomo || die "写入 /etc/config/mihomo 失败"
}

# ---- 命令 ----

do_set() {
	local enabled="$1" target="$2" schedule="$3" legacyurl="$4" url

	case "$enabled" in
		1) enabled=1 ;;
		*) enabled=0 ;;
	esac

	if [ "$enabled" = "1" ]; then
		[ -n "$target" ] || die "已启用定时更新, 但没有选择目标配置"
		[ -n "$schedule" ] || schedule="$DEFAULT_SCHEDULE"
		validate_target "$target"
		validate_schedule "$schedule"
		# 目标文件必须先存在, 否则写进 uci 的会是一条永远失败的计划任务
		[ -f "$WORKDIR/$target" ] \
			|| die "目标配置不存在: $WORKDIR/$target (请先导入或创建该配置文件)"
		# 链接必须有记录: 定时任务是无人值守的, 到点才发现没链接就白跑一轮。
		url="$(source_get "$target")"
		[ -n "$url" ] || die "配置 $target 没有记录订阅链接, 无法定时更新 (请先用订阅链接导入一次, 或在「仅更新」里填写链接并执行一次)"
	else
		[ -n "$target" ] && validate_target "$target"
		[ -n "$schedule" ] && validate_schedule "$schedule"
	fi

	# 旧页面 (浏览器缓存未刷新) 仍会带第 4 个参数: 不写进 uci, 也不静默丢弃 ——
	# 明确告一声, 免得用户以为自己填的链接生效了。
	[ -n "$legacyurl" ] && echo "注意: 定时更新的订阅链接不再单独保存, 传入的链接已被忽略; 来源统一取 $WORKDIR/sources 里该配置的记录。"

	uci_save_settings "$enabled" "$target" "$schedule"

	# 写完 uci 立刻生效 (apply 自己会读回刚写的值)
	do_apply
}

do_apply() {
	local enabled target schedule url line

	config_load mihomo
	config_get enabled  "autoupdate" "enabled"  "0"
	config_get target   "autoupdate" "target"   ""
	config_get schedule "autoupdate" "schedule" "$DEFAULT_SCHEDULE"

	[ -n "$schedule" ] || schedule="$DEFAULT_SCHEDULE"

	if [ "$enabled" != "1" ]; then
		do_remove
		echo "定时更新已关闭, 计划任务已移除"
		return 0
	fi

	[ -n "$target" ] || die "已启用定时更新, 但没有选择目标配置"
	validate_target "$target"
	validate_schedule "$schedule"
	validate_arg "$target"

	[ -f "$WORKDIR/$target" ] \
		|| die "目标配置不存在: $WORKDIR/$target (请先导入或创建该配置文件)"

	# 链接只用来「确认有货」并展示, 不写进 cron: 命令里只留目标文件名, 由
	# config.sh update 运行时查 sources —— 这样换目标时链接自然跟着换。
	url="$(source_get "$target")"
	[ -n "$url" ] || die "配置 $target 没有记录订阅链接, 无法定时更新 (请先用订阅链接导入一次, 或在「仅更新」里填写链接并执行一次)"

	line="$schedule PATH=$CRON_PATH $HELPER update '$target'"
	line="$line 2>&1 | logger -t $LOG_TAG"

	write_crontab "$line"
	cron_reload

	echo "定时更新已启用"
	echo "目标配置: $WORKDIR/$target"
	echo "执行时间: $schedule"
	echo "来源链接: $url (取自 $WORKDIR/sources, 换目标配置时随之切换)"
	echo "计划任务: $line"
	echo "更新结果与失败原因会写入系统日志 (logger -t $LOG_TAG)。"
}

do_remove() {
	config_load mihomo
	config_get enabled "autoupdate" "enabled" "0"

	write_crontab ""
	cron_reload

	echo "计划任务已移除"
}

do_status() {
	local enabled target schedule url rc_enabled rc_running line

	config_load mihomo
	config_get enabled  "autoupdate" "enabled"  "0"
	config_get target   "autoupdate" "target"   ""
	config_get schedule "autoupdate" "schedule" "$DEFAULT_SCHEDULE"

	line="$(managed_line)"

	if [ "$enabled" = "1" ]; then
		echo "定时更新: 已启用"
	else
		echo "定时更新: 未启用"
	fi

	echo "目标配置: ${target:-（未选择）}"
	echo "执行时间: ${schedule:-（未设置）}"

	url=""
	[ -n "$target" ] && url="$(source_get "$target")"
	if [ -n "$url" ]; then
		echo "来源链接: $url (取自 $WORKDIR/sources)"
	elif [ -n "$target" ]; then
		echo "来源链接: 该配置没有记录订阅链接, 定时任务会失败 (请在「仅更新」里填写链接并执行一次)"
	else
		echo "来源链接: （未选择目标配置）"
	fi

	if ls /etc/rc.d/S*cron >/dev/null 2>&1; then
		echo "cron 服务: 已设置为开机启用"
	else
		echo "cron 服务: 未设置开机启用"
	fi

	if /etc/init.d/cron running >/dev/null 2>&1; then
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
		load_config
		do_apply
		;;
	set)
		load_config
		do_set "$1" "$2" "$3" "$4"
		;;
	remove)
		load_config
		do_remove
		;;
	status)
		load_config
		do_status
		;;
	help|-h|--help|"")
		cat <<EOF
Usage: $0 apply | set <enabled> <target> <schedule> | remove | status

  apply   读 uci mihomo.autoupdate 并把计划任务写入 $CRONTAB
  set     用给定值写 uci mihomo.autoupdate 随后生效 (LuCI 页面用这条)
          enabled  1/0
          target   目标配置文件名, 关闭时可以留空
          schedule cron 时间字段 (5 段), 关闭时可以留空
          订阅链接不在这里传: 来源统一取 <workdir>/sources 里该配置的记录
          (兼容旧页面: 多传的第 4 个参数会被忽略并给出提示)
  remove  移除定时更新写入的计划任务
  status  打印当前状态
EOF
		;;
	*)
		echo "未知命令: $cmd" >&2
		exit 1
		;;
esac

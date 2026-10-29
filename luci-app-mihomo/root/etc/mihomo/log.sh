#!/bin/sh
# mihomo 运行日志的查看与维护（LuCI「运行状态」页的日志面板调用本脚本）。
#
#   log.sh status            打印 file / exists / size / max_kb / lines, 供页面显示
#   log.sh tail [N]          打印最后 N 行 (默认 200, 上限 2000); 超上限时先裁剪
#   log.sh page <start> <lim>  从第 start 行开始取 lim 行, 供页面「加载更早」分页回查
#   log.sh clear             清空当前日志
#   log.sh trim              超过上限时只保留最新的 max_kb KB
#   log.sh setmax <KB>       把上限写入 uci mihomo.main.log_max_kb
#
# 为什么一律「原地截断」而不是删文件/改文件名:
#   mihomo 由 procd 拉起时以 O_APPEND 持有这个文件的 fd。删掉或 rename 之后它
#   仍然写向旧 inode —— 新文件永远收不到内容, 表现成"日志写着写着就空了"。
#   原地截断则下一行从新的 EOF 继续追加, 语义正确, 且服务不用重启。
#
# 配置读取: 直接用命令行 uci 读 /etc/config/mihomo。setmax 也用命令行 uci 写入
# (不是 rpcd 的 uci.apply) —— 后者会让注册了 procd_add_reload_trigger 的服务执行
# reload, 也就是"改个日志上限把代理重启一次"。上限只被本脚本和 init 消费,
# 不需要重启就生效。与 autorestart.sh / autoupdate.sh 的处理一致。

LOG_FILE=`uci -q get mihomo.main.log_file`
MAX_KB=`uci -q get mihomo.main.log_max_kb`

# 默认值与 init / mihomo.config 保持一致。log_file 留空按默认处理;
# 想彻底不落盘就把 log_file 指向 /dev/null。
[ -n "$LOG_FILE" ] || LOG_FILE="/var/log/mihomo.log"
case "$MAX_KB" in
	''|*[!0-9]*) MAX_KB=1024 ;;
esac
[ "$MAX_KB" -ge 16 ] || MAX_KB=16

die() {
	echo "错误: $*" >&2
	exit 1
}

log_size() {
	if [ -f "$LOG_FILE" ]; then
		wc -c < "$LOG_FILE" 2>/dev/null | tr -d ' \n'
	else
		echo 0
	fi
}

# 行数。用 awk 而不是 wc -l: 末尾没有换行时 wc -l 会少算一行,
# 而 tail -c 裁剪正好可能把最后一行留在没有换行的状态。
log_lines() {
	if [ -f "$LOG_FILE" ]; then
		awk 'END { print NR + 0 }' "$LOG_FILE" 2>/dev/null || echo 0
	else
		echo 0
	fi
}

# 裁剪到最新的 max_kb KB。调用方负责保证"写者不在写"(init 启动前) 或接受
# 极短窗口内可能丢一两行(页面刷新时) —— 见文件头的说明。
do_trim() {
	[ -f "$LOG_FILE" ] || return 0

	local limit size tmp
	limit=$((MAX_KB * 1024))
	size=$(log_size)
	[ "$size" -gt "$limit" ] || return 0

	tmp="$LOG_FILE.trim.$$"
	tail -c "$limit" "$LOG_FILE" > "$tmp" || { rm -f "$tmp"; return 1; }
	cat "$tmp" > "$LOG_FILE" || { rm -f "$tmp"; return 1; }
	rm -f "$tmp"
	echo "已裁剪: $size -> $limit 字节 (保留最新内容)" >&2
	return 0
}

cmd_status() {
	local exists=0 size=0
	if [ -f "$LOG_FILE" ]; then
		exists=1
		size=$(log_size)
	fi
	printf 'file=%s\n' "$LOG_FILE"
	printf 'exists=%s\n' "$exists"
	printf 'size=%s\n' "$size"
	printf 'max_kb=%s\n' "$MAX_KB"
	printf 'lines=%s\n' "$(log_lines)"
	return 0
}

# 按绝对行号取一段, 供页面「加载更早」分页回查。
#   page <start> <lim>: 从第 start 行(1 起)开始取 lim 行, 按时间正序打印。
#
# 为什么用绝对行号而不是"跳过末尾 N 行": 日志在用户翻历史时仍在追加。
# 「跳过末尾 N 行」会随文件增长整体前移 —— 上翻时取到的其实是新写入的尾部,
# 插到顶部就把时间顺序打乱了。绝对行号只随头部裁剪(trim)失效, 而 trim 必然
# 伴随总行数下降, 页面据此重置即可。
cmd_page() {
	local start="$1" lim="$2" total
	case "$start" in ''|*[!0-9]*) start=1 ;; esac
	case "$lim" in ''|*[!0-9]*) lim=200 ;; esac
	[ "$start" -ge 1 ] || start=1
	[ "$lim" -ge 1 ] || lim=200
	[ "$lim" -le 2000 ] || lim=2000

	[ -f "$LOG_FILE" ] || return 0
	do_trim || true

	total=$(log_lines)
	[ "$total" -ge "$start" ] || return 0
	tail -n +"$start" "$LOG_FILE" | head -n "$lim"
	return 0
}

cmd_tail() {
	local n="$1"
	case "$n" in
		''|*[!0-9]*) n=200 ;;
	esac
	[ "$n" -ge 1 ] || n=200
	[ "$n" -le 2000 ] || n=2000

	[ -f "$LOG_FILE" ] || return 0
	do_trim || true
	tail -n "$n" "$LOG_FILE"
	return 0
}

cmd_clear() {
	[ -f "$LOG_FILE" ] || { echo "日志文件不存在: $LOG_FILE"; return 0; }
	: > "$LOG_FILE" || die "清空失败: $LOG_FILE"
	echo "已清空: $LOG_FILE"
	return 0
}

cmd_trim() {
	do_trim || die "裁剪失败: $LOG_FILE"
	return 0
}

cmd_setmax() {
	local v="$1"
	case "$v" in
		''|*[!0-9]*) die "上限必须是整数 (单位 KB)" ;;
	esac
	[ "$v" -ge 16 ] || die "上限太小: ${v} KB (最小 16 KB)"
	[ "$v" -le 102400 ] || die "上限太大: ${v} KB (最大 102400 KB)"
	uci set "mihomo.main.log_max_kb=$v" || die "写入 uci 失败"
	uci commit mihomo || die "提交 uci 失败"
	echo "日志上限已设为 ${v} KB"
	return 0
}

case "$1" in
	status)  cmd_status ;;
	tail)    cmd_tail "$2" ;;
	page)    cmd_page "$2" "$3" ;;
	clear)   cmd_clear ;;
	trim)    cmd_trim ;;
	setmax)  cmd_setmax "$2" ;;
	*)
		echo "用法: $0 {status|tail [N]|page <start> <limit>|clear|trim|setmax <KB>}" >&2
		exit 1
		;;
esac

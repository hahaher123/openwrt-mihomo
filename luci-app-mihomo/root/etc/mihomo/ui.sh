#!/bin/sh
# mihomo 外部面板 (external-ui / metacubexd 等) 安装器。
#
#   ui.sh status            打印机器可读的状态 (页面轮询用, 很快)
#   ui.sh start [url]       后台下载并安装面板, 立即返回
#   ui.sh install [url]     前台下载并安装 (调试用, 页面不走这条路)
#   ui.sh remove            删除面板目录
#   ui.sh help
#
# 为什么页面用 start + 轮询而不是直接 install:
#   LuCI 的 rpc 调用超时由 L.env.rpctimeout 决定 (luci-base 的 rpc.js:
#   `timeout: (L.env.rpctimeout ?? 20) * 1000`), 默认只有 20 秒, 而
#   rpc.declare 不能按调用覆盖它。面板 zip 约 2.5 MB, 慢速链路上 20 秒
#   肯定不够, 直接前台跑会得到一个「Request timeout」的假失败。所以
#   install 拆成两段: start 把真正的下载解压丢到后台并立刻返回, 页面只
#   轮询 status (只读几个文件, 毫秒级), 撞不到超时。
#
# 目标目录 = 当前生效配置里的 "external-ui":
#   相对路径按 workdir 解析 (mihomo 的 constant/path.go: Resolve 用
#   HomeDir), 绝对路径原样使用; 配置里没有该键时用 <workdir>/ui —— 这
#   正是页面提示用户填的那个值。⚠ 注意即使面板文件装好了, 只要配置里
#   没有 external-ui, mihomo 也不会注册 /ui 路由 (hub/hub.go: 只有
#   cfg.Controller.ExternalUI != "" 才 SetUIPath), 页面会给出提示。

[ -s /lib/functions.sh ] && . /lib/functions.sh

WORKDIR="/etc/mihomo"
CONFFILE="/etc/mihomo/config.yaml"

# 面板的默认来源。metacubexd 的 gh-pages 分支就是它的构建产物目录,
# mihomo 自己的 external-ui-url 默认值也是这个地址 (config/config.go:
# DefaultRawConfig)。用户可以在页面上换成镜像或其它面板的 zip。
DEFAULT_UI_URL="https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.zip"

# 下载: 整体超时给得很宽 —— 2.5 MB 在慢速线路上可能要几分钟, 而这条
# 路径已经在后台跑了, 不存在把页面阻塞住的问题。
TIMEOUT="600"
CONNECT_TIMEOUT="20"
USER_AGENT="mihomo-luci"

# 任务状态 (页面轮询的接口)。全放 /tmp: 掉电就丢, 重启后回到 idle,
# 不需要任何清理逻辑。
JOB_STATE="/tmp/mihomo-ui.state"
JOB_RC="/tmp/mihomo-ui.rc"
JOB_PID="/tmp/mihomo-ui.pid"
JOB_LOG="/tmp/mihomo-ui.log"

EXTERNAL_UI=""
EXTERNAL_CONTROLLER=""
UI_DIR=""
UI_INVALID=""

UI_TMP=""
UI_NEW=""

usage() {
	cat <<EOF
Usage: $0 status
       $0 start [url]
       $0 install [url]
       $0 remove
       $0 help

  status   打印当前状态, 每行 "KEY: value"
  start    后台下载并安装 (页面用), 立刻返回 "RESULT: started"
  install  前台下载并安装 (调试用)
  remove   删除面板目录

  url      面板 zip 地址, 省略则用 $DEFAULT_UI_URL

目标目录取自当前生效配置的 "external-ui" (相对 workdir), 缺省为
<workdir>/ui。安装时会先解压到同目录下的临时目录, 校验 index.html
之后再整体替换, 失败则保留原来的面板。
EOF
}

die() {
	echo "错误: $*" >&2
	exit 1
}

cleanup() {
	[ -n "$UI_TMP" ] && rm -rf "$UI_TMP"
	[ -n "$UI_NEW" ] && [ -d "$UI_NEW" ] && rm -rf "$UI_NEW"
	return 0
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# 配置
# ---------------------------------------------------------------------------

# 与 /etc/init.d/mihomo、config.sh 读同一份 uci
load_config() {
	WORKDIR="/etc/mihomo"
	CONFFILE="/etc/mihomo/config.yaml"

	if [ -f /etc/config/mihomo ]; then
		config_load mihomo
		config_get WORKDIR "main" "workdir" "/etc/mihomo"
		config_get CONFFILE "main" "conffile" "/etc/mihomo/config.yaml"
	fi
}

# 取配置里某个顶层键的值: 去掉行尾注释、首尾空白与成对引号。
# 只匹配行首 (clash/mihomo 的顶层键不缩进), 所以和缩进在块里的
# 同名子项不会混淆。
#
# 一个 sed 干完所有事: 这条路径每次页面轮询都会跑 (status 每 3 秒被调
# 一次), 低端路由器上每 fork 一次都有成本, 而 sed|head|sed|sed 是 4 个
# 进程。`s///` 复用上一个匹配的正则, `q` 相当于 head -n 1。
conf_value() {
	[ -f "$CONFFILE" ] || return 0

	sed -n "/^$1[[:space:]]*:[[:space:]]*/{
		s///;
		s/[[:space:]]#.*\$//;
		s/[[:space:]]*\$//;
		s/^\"\(.*\)\"\$/\1/;
		s/^'\(.*\)'\$/\1/;
		p;
		q;
	}" "$CONFFILE" 2>/dev/null
}

resolve_ui_dir() {
	EXTERNAL_UI=$(conf_value "external-ui")
	EXTERNAL_CONTROLLER=$(conf_value "external-controller")
	UI_INVALID=""

	case "$EXTERNAL_UI" in
		'') UI_DIR="$WORKDIR/ui" ;;
		/*) UI_DIR="$EXTERNAL_UI" ;;
		*)  UI_DIR="$WORKDIR/$EXTERNAL_UI" ;;
	esac

	# external-ui 可以是任意字符串, 这里拦住会逃出 workdir 或指到根/自身
	# 的写法 —— remove 会 rm -rf 这个目录, 不能由配置文件随便决定。
	case "$UI_DIR" in
		""|"/"|"$WORKDIR"|"$WORKDIR/")
			UI_INVALID="目录为空或指向 workdir 本身" ;;
		*/../*|*/..|../*|..)
			UI_INVALID="包含 .. 路径片段" ;;
	esac
}

# ---------------------------------------------------------------------------
# 统计
# ---------------------------------------------------------------------------

count_files() {
	find "$1" -type f 2>/dev/null | wc -l | tr -d ' '
}

dir_size() {
	set -- $(du -sk "$1" 2>/dev/null)
	[ $# -ge 1 ] && echo $(($1 * 1024))
}

fmt_size() {
	n="$1"

	[ -n "$n" ] || { echo "?"; return; }

	if [ "$n" -lt 1024 ]; then
		echo "$n B"
	elif [ "$n" -lt 1048576 ]; then
		echo "$((n / 1024)) KB"
	else
		echo "$((n / 1048576)) MB"
	fi
}

# ---------------------------------------------------------------------------
# 下载
# ---------------------------------------------------------------------------

fetch_tool() {
	if command -v curl >/dev/null 2>&1; then
		echo curl
	elif command -v wget >/dev/null 2>&1; then
		echo wget
	elif command -v uclient-fetch >/dev/null 2>&1; then
		echo uclient-fetch
	fi
}

fetch() {
	url="$1"
	out="$2"
	log="$3"
	tool=""

	tool=$(fetch_tool)
	[ -n "$tool" ] || die "未找到可用的下载工具 (curl / wget / uclient-fetch)"

	case "$tool" in
		curl)
			curl -fsSL -A "$USER_AGENT" --connect-timeout "$CONNECT_TIMEOUT" \
				--max-time "$TIMEOUT" -o "$out" "$url" >"$log" 2>&1 ;;
		wget)
			wget -T "$TIMEOUT" -U "$USER_AGENT" -O "$out" "$url" >"$log" 2>&1 ;;
		*)
			uclient-fetch -T "$TIMEOUT" -O "$out" "$url" >"$log" 2>&1 ;;
	esac
}

# 解压工具: 独立的 unzip 包优先, 其次 busybox 里的 applet (多数固件没编)。
unzip_cmd() {
	if command -v unzip >/dev/null 2>&1; then
		echo "unzip"
	elif busybox unzip 2>&1 | grep -qi 'usage'; then
		echo "busybox unzip"
	fi
}

# ---------------------------------------------------------------------------
# 安装
# ---------------------------------------------------------------------------

# zip 里通常带一层顶层目录 (metacubexd-gh-pages/), 直接装上去会让
# /ui 下面再多一级。只有一个顶层目录且下面没有别的文件时上提一层 ——
# 与 mihomo 自己解压后 moveDir() 的行为一致 (component/updater/update_ui.go)。
flatten_topdir() {
	dir="$1"
	parent=""
	flat=""
	only=""

	# 一次 ls 拿到全部条目个数 + 第一个名字: ls|wc -l 再加一次 ls 是
	# 3 个进程, 而这里只需要"是不是只有一个"。
	set -- $(ls -A "$dir" 2>/dev/null)
	[ $# -eq 1 ] || return 0

	only="$1"
	[ -d "$dir/$only" ] || return 0

	# 暂存路径必须在这里算好并且不再经过 $dir —— rmdir 之后 "$dir/.."
	# 就解析不出来了 (中间的 $dir 已经不存在), 那正是第一版把面板装丢的
	# 原因。
	parent=$(dirname "$dir")
	flat="$parent/.mihomo-ui-flat.$$"

	echo "去掉 zip 的顶层目录: $only/"

	mv "$dir/$only" "$flat" || return 1

	if ! rmdir "$dir"; then
		mv "$flat" "$dir/$only"
		return 1
	fi

	mv "$flat" "$dir" || return 1

	return 0
}

ui_install_main() {
	url="$1"
	ui_parent=""

	[ -n "$url" ] || url="$DEFAULT_UI_URL"

	case "$url" in
		http://*|https://*|file://*) ;;
		*) die "只支持 http:// / https:// / file:// 开头的 URL" ;;
	esac

	[ -n "$UI_INVALID" ] && die "external-ui 指向的目录不可用 ($UI_INVALID), 请先在配置里改正"

	zipcmd=$(unzip_cmd)
	[ -n "$zipcmd" ] || die "缺少解压工具 unzip, 请先安装 unzip 包 (apk add unzip)"

	ui_parent=$(dirname "$UI_DIR")
	mkdir -p "$ui_parent" || die "无法创建目录 $ui_parent"

	# zip 放 /tmp (内存盘), 解压目标是 UI_DIR 的同级隐藏目录 —— 同一
	# 文件系统才能用 mv 原子替换, 跨设备 mv 会退化成复制, 中途失败就
	# 会留下半个面板。
	UI_TMP="/tmp/mihomo-ui.$$"
	UI_NEW="$ui_parent/.mihomo-ui-new.$$"

	rm -rf "$UI_TMP" "$UI_NEW"
	mkdir -p "$UI_TMP" "$UI_NEW" || die "无法创建临时目录"

	echo "== 下载 =="
	echo "URL:  $url"
	echo "目标: $UI_DIR"
	echo

	if ! fetch "$url" "$UI_TMP/download.zip" "$UI_TMP/fetch.log"; then
		echo "-- 下载工具输出 --"
		tail -n 8 "$UI_TMP/fetch.log" 2>/dev/null
		echo
		die "下载失败, 请检查地址是否可访问 (GitHub 在部分网络下需要代理)"
	fi

	[ -s "$UI_TMP/download.zip" ] || die "下载失败: 得到 0 字节内容"

	echo "已下载 $(wc -c < "$UI_TMP/download.zip" | tr -d ' ') 字节"
	echo

	echo "== 解压 =="
	$zipcmd -q -o "$UI_TMP/download.zip" -d "$UI_NEW" >"$UI_TMP/unzip.log" 2>&1
	if [ $? -ne 0 ]; then
		echo "-- 解压工具输出 --"
		tail -n 8 "$UI_TMP/unzip.log" 2>/dev/null
		echo
		die "解压失败, 下载到的内容可能不是有效的 zip (被网关/代理拦截成网页?)"
	fi

	flatten_topdir "$UI_NEW" || die "整理 zip 顶层目录失败"

	# 面板必须是静态前端: 没有 index.html 的东西装上去只会让 /ui 404,
	# 不如在这里拦下来。
	[ -f "$UI_NEW/index.html" ] || die "解压后找不到 index.html, 这个 zip 看起来不是面板前端"

	# 统计一次就够: 后面 mv 到 UI_DIR 是同一个文件系统内的重命名, 文件数
	# 与占用都不会变, 不必再数一遍 (每次统计要 fork find/du/wc)。
	files=$(count_files "$UI_NEW")
	size=$(dir_size "$UI_NEW")

	echo "解压完成: $files 个文件, $(fmt_size "$size")"
	echo

	echo "== 安装 =="
	old="$ui_parent/.mihomo-ui-old.$$"
	moved_old=0

	if [ -e "$UI_DIR" ]; then
		mv "$UI_DIR" "$old" || die "无法移走旧面板目录 $UI_DIR"
		moved_old=1
		echo "旧面板: $(count_files "$old") 个文件, $(fmt_size "$(dir_size "$old")"), 已移到一边"
	fi

	if ! mv "$UI_NEW" "$UI_DIR"; then
		[ "$moved_old" = 1 ] && mv "$old" "$UI_DIR"
		die "无法把新面板放到 $UI_DIR, 旧面板已还原"
	fi

	[ "$moved_old" = 1 ] && rm -rf "$old"

	echo "已安装: $UI_DIR"
	echo "文件数: $files"
	echo "占用:   $(fmt_size "$size")"
	echo

	if [ -z "$EXTERNAL_UI" ]; then
		echo "注意: 当前配置 ($CONFFILE) 里没有 external-ui, mihomo 不会注册 /ui 路由。"
		echo "      请在配置里加上 external-ui: ui 并重启服务, 面板才会生效。"
	elif [ -z "$EXTERNAL_CONTROLLER" ]; then
		echo "注意: 当前配置里没有 external-controller, 面板没有可连接的 API。"
		echo "      请加上 external-controller: 0.0.0.0:9090 并重启服务。"
	else
		echo "面板地址: http://<路由器地址>:9090/ui (external-ui: $EXTERNAL_UI)"
		echo "静态文件直接读磁盘, 不需要重启 mihomo。"
	fi

	echo
	echo "RESULT: installed"
}

# ---------------------------------------------------------------------------
# 后台任务
# ---------------------------------------------------------------------------

# 读任务状态一律用 read 内建, 不用 cat: status 是页面每 3 秒轮询一次的
# 热路径, 而 read 不 fork。
job_running() {
	st=""
	pid=""

	read -r st < "$JOB_STATE" 2>/dev/null || return 1
	[ "$st" = "running" ] || return 1

	read -r pid < "$JOB_PID" 2>/dev/null || return 1
	[ -n "$pid" ] || return 1

	kill -0 "$pid" 2>/dev/null
}

job_state() {
	st=""

	read -r st < "$JOB_STATE" 2>/dev/null || st=""

	case "$st" in
		running)
			# 状态说在跑、进程却没了: 子 shell 被外部杀掉 (重启服务、
			# 手动 kill), 不会有人再写 done/failed, 这里直接判失败,
			# 免得页面永远转圈。
			if job_running; then echo "running"; else echo "failed"; fi ;;
		done|failed)
			echo "$st" ;;
		*)
			echo "idle" ;;
	esac
}

do_start() {
	url="$1"

	if job_running; then
		echo "已有安装任务在运行 (pid $(cat "$JOB_PID" 2>/dev/null)), 请等它结束。"
		echo "RESULT: busy"
		return 0
	fi

	rm -f "$JOB_RC"
	printf 'running\n' > "$JOB_STATE"
	: > "$JOB_LOG"

	# 关键: 后台子 shell 的三个标准流必须全部重定向到文件。rpcd 的
	# file.exec 靠管道 EOF 判断命令结束, 后台进程如果继承了那对管道,
	# 它就一直等不到 EOF, 页面这边的 rpc 调用会挂到超时。
	(
		ui_install_main "$url" >>"$JOB_LOG" 2>&1
		rc=$?
		echo "$rc" > "$JOB_RC"
		if [ "$rc" -eq 0 ]; then
			printf 'done\n' > "$JOB_STATE"
		else
			printf 'failed\n' > "$JOB_STATE"
		fi
		rm -f "$JOB_PID"
	) >>"$JOB_LOG" 2>&1 </dev/null &

	echo $! > "$JOB_PID"

	echo "已在后台开始下载并安装面板"
	echo "日志: $JOB_LOG"
	echo "RESULT: started"
}

# ---------------------------------------------------------------------------
# 删除
# ---------------------------------------------------------------------------

do_remove() {
	[ -n "$UI_DIR" ] || die "无法解析面板目录 (external-ui 为空且 workdir 未知)"
	[ -n "$UI_INVALID" ] && die "external-ui 指向的目录不可用 ($UI_INVALID), 拒绝删除"

	if [ ! -e "$UI_DIR" ]; then
		echo "$UI_DIR 不存在, 无需删除。"
		echo "RESULT: absent"
		return 0
	fi

	n=$(count_files "$UI_DIR")
	s=$(fmt_size "$(dir_size "$UI_DIR")")

	rm -rf "$UI_DIR" || die "删除 $UI_DIR 失败"

	echo "已删除: $UI_DIR (原有 $n 个文件, $s)"
	echo "mihomo 不会因此重启; 重新访问 /ui 会得到 404, 直到重新安装或让 mihomo 自行下载。"
	echo "RESULT: removed"
}

# ---------------------------------------------------------------------------
# 状态
# ---------------------------------------------------------------------------

do_status() {
	resolve_ui_dir

	echo "WORKDIR: $WORKDIR"
	echo "CONFFILE: $CONFFILE"
	echo "EXTERNAL_UI: $EXTERNAL_UI"
	echo "EXTERNAL_CONTROLLER: $EXTERNAL_CONTROLLER"
	echo "UI_DIR: $UI_DIR"
	echo "UI_INVALID: $UI_INVALID"
	echo "DEFAULT_URL: $DEFAULT_UI_URL"

	if [ -d "$UI_DIR" ]; then
		echo "UI_STATE: installed"
		echo "UI_FILES: $(count_files "$UI_DIR")"
		echo "UI_SIZE: $(dir_size "$UI_DIR")"
		echo "UI_MTIME: $(stat -c %Y "$UI_DIR" 2>/dev/null)"
		if [ -f "$UI_DIR/index.html" ]; then
			echo "UI_INDEX: yes"
		else
			echo "UI_INDEX: no"
		fi
	else
		echo "UI_STATE: missing"
		echo "UI_FILES: 0"
		echo "UI_SIZE: 0"
		echo "UI_MTIME: "
		echo "UI_INDEX: no"
	fi

	echo "JOB: $(job_state)"
	rc=""
	read -r rc < "$JOB_RC" 2>/dev/null || rc=""
	echo "JOB_RC: $rc"
	echo "JOB_LOG: $JOB_LOG"
	echo "RESULT: ok"
}

cmd="$1"
[ $# -gt 0 ] && shift

case "$cmd" in
	status)
		load_config
		do_status
		;;
	start)
		load_config
		resolve_ui_dir
		do_start "$1"
		;;
	install)
		load_config
		resolve_ui_dir
		ui_install_main "$1"
		;;
	remove)
		load_config
		resolve_ui_dir
		do_remove
		;;
	help|-h|--help|"")
		usage
		;;
	*)
		echo "未知命令: $cmd" >&2
		echo >&2
		usage >&2
		exit 1
		;;
esac

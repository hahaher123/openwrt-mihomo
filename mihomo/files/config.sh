#!/bin/sh
# mihomo configuration manager.
#
#   config.sh import <url> [name] [force]   download a remote clash/mihomo
#                                          profile, validate it and install it
#                                          into the work directory
#   config.sh help
#
# Only the network facing part lives here; the LuCI "配置文件" page handles
# listing, reading, editing and installing edited files directly through the
# rpcd file API and calls this script for imports.
#
# The work directory and the config file name are read from /etc/config/mihomo
# so that this script always agrees with /etc/init.d/mihomo.

[ -s /lib/functions.sh ] && . /lib/functions.sh

PROG="/usr/bin/mihomo"
TIMEOUT="60"

TMP=""
STAGE=""
cleanup() {
	[ -n "$TMP" ] && rm -f "$TMP"
	[ -n "$STAGE" ] && rm -f "$STAGE"
	return 0
}
trap cleanup EXIT INT TERM

usage() {
	cat <<EOF
Usage: $0 import <url> [name] [force]
       $0 help

  url     remote profile URL (http/https)
  name    target file name inside the work directory; defaults to a name
          derived from the URL, a .yaml suffix is appended when missing
  force   overwrite the target if it already exists

The downloaded profile is validated with "mihomo -t" before it is installed;
an invalid profile is never written into the work directory.
EOF
}

die() {
	echo "错误: $*" >&2
	exit 1
}

# Resolve workdir/conffile exactly like /etc/init.d/mihomo does.
load_config() {
	WORKDIR="/etc/mihomo"
	CONFFILE="/etc/mihomo/config.yaml"

	if [ -f /etc/config/mihomo ]; then
		config_load mihomo
		config_get WORKDIR "main" "workdir" "/etc/mihomo"
		config_get CONFFILE "main" "conffile" "/etc/mihomo/config.yaml"
	fi
}

# Derive a usable file name from a URL: drop query/fragment, keep the last
# path component, so ".../sub?token=abc" becomes "sub.yaml".
name_from_url() {
	name=$(printf '%s' "$1" | sed -e 's/[?#].*$//' -e 's#.*/##')
	name="${name%.yaml}"
	name="${name%.yml}"
	[ -n "$name" ] || name="import"
	echo "$name.yaml"
}

# Normalise a user supplied file name and make sure it cannot escape the work
# directory; this is the only place that decides what may be written there.
# A missing .yaml/.yml suffix is appended (as documented in usage), anything
# else is rejected. The result is put into $NAME rather than echoed: a die()
# inside a command substitution would only kill the subshell and let the caller
# continue with an empty name.
NAME=""
normalize_name() {
	case "$1" in
		*.yaml|*.yml) NAME="$1" ;;
		*)            NAME="$1.yaml" ;;
	esac

	case "$NAME" in
		*/*|*\\*|.|..|.*)
			die "非法文件名 '$1' (不允许路径与隐藏文件)" ;;
	esac
	case "$NAME" in
		*[!A-Za-z0-9._-]*)
			die "非法文件名 '$1' (只允许 A-Za-z0-9 . _ - )" ;;
	esac
}

fetch() {
	url="$1"
	out="$2"

	if command -v uclient-fetch >/dev/null 2>&1; then
		uclient-fetch -q -T "$TIMEOUT" -O "$out" "$url"
	elif command -v wget >/dev/null 2>&1; then
		wget -q -T "$TIMEOUT" -O "$out" "$url"
	elif command -v curl >/dev/null 2>&1; then
		curl -fsSL --max-time "$TIMEOUT" -o "$out" "$url"
	else
		die "未找到可用的下载工具 (uclient-fetch / wget / curl)"
	fi
}

# Run the upstream validator on a candidate file, mirroring the invocation of
# /etc/init.d/mihomo ("-f <config> -d <workdir>"). Prints the validator output
# and returns its exit code. mihomo logs to stdout (log.SetOutput(os.Stdout)),
# so the diagnostics of a failed check appear on stdout, not on stderr.
check_file() {
	"$PROG" -t -f "$1" -d "$WORKDIR" 2>&1
}

do_import() {
	url="$1"
	name="$2"
	force="$3"

	[ -n "$url" ] || die "缺少 URL"

	case "$url" in
		http://*|https://*) ;;
		*) die "只支持 http:// 与 https:// 开头的 URL" ;;
	esac

	[ -n "$name" ] || name="$(name_from_url "$url")"
	normalize_name "$name"
	name="$NAME"

	[ -x "$PROG" ] || die "mihomo 主程序不存在: $PROG"

	TARGET="$WORKDIR/$name"

	if [ -e "$TARGET" ] && [ "$force" != "force" ]; then
		die "$TARGET 已存在 (如需覆盖请在页面上勾选\"覆盖同名文件\")"
	fi

	mkdir -p "$WORKDIR" || die "无法创建目录 $WORKDIR"

	# Download and validate in /tmp: the candidate must never appear in the
	# work directory before it passed the check, and /tmp avoids flash writes.
	TMP="/tmp/mihomo-import.$$.yaml"

	echo "== 下载 =="
	echo "URL:  $url"
	echo "目标: $TARGET"
	echo

	if ! fetch "$url" "$TMP"; then
		echo
		die "下载失败 ($url)"
	fi

	[ -s "$TMP" ] || die "下载内容为空 ($url)"

	SIZE=$(wc -c < "$TMP" | tr -d ' ')
	echo "已下载 $SIZE 字节"
	echo

	echo "== 校验 (mihomo -t) =="
	if ! check_file "$TMP"; then
		echo
		die "配置文件未通过校验, 未写入 $TARGET"
	fi
	echo

	# Rename within the same directory so the target is either the old or the
	# new file, never a half written one. 0600 matches INSTALL_CONF.
	STAGE="$WORKDIR/.$name.$$"
	cp -f "$TMP" "$STAGE" || die "写入暂存文件失败 ($STAGE)"
	chmod 600 "$STAGE"
	if ! mv -f "$STAGE" "$TARGET"; then
		die "替换 $TARGET 失败"
	fi
	STAGE=""

	echo "== 完成 =="
	echo "已导入: $TARGET"

	if [ "$TARGET" = "$CONFFILE" ]; then
		echo "该文件正是当前生效的配置, 重启 mihomo 服务后生效。"
	else
		echo "当前生效的配置是 $CONFFILE"
		echo "如需使用新配置, 请在页面上选中它并点击\"设为当前配置并重启\"。"
	fi
}

cmd="$1"
[ $# -gt 0 ] && shift

case "$cmd" in
	import)
		load_config
		do_import "$1" "$2" "$3"
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

#!/bin/sh
# mihomo configuration manager.
#
#   config.sh import <url> [name] [force]   download a remote clash/mihomo
#                                           profile, validate it and install
#                                           it into the work directory
#   config.sh update <name> [url]           re-download the subscription and
#                                           replace ONLY the "proxies" and
#                                           "proxy-groups" sections of an
#                                           existing profile. When the remote
#                                           sections are identical to the local
#                                           ones nothing is written and the
#                                           service is left alone; when they
#                                           differ the file is updated and
#                                           mihomo is restarted.
#   config.sh help
#
# Only the network facing part lives here; the LuCI "配置文件" page handles
# listing, reading, editing and installing edited files directly through the
# rpcd file API and calls this script for imports and section-only updates.
#
# The work directory and the config file name are read from /etc/config/mihomo
# so that this script always agrees with /etc/init.d/mihomo.
#
# Subscription URLs are remembered in <workdir>/sources ("<name> <url>" per
# line, mode 0600) so that "update" can be re-run without retyping the URL.

[ -s /lib/functions.sh ] && . /lib/functions.sh

PROG="/usr/bin/mihomo"
INITD="/etc/init.d/mihomo"

# 下载: 单次请求整体超时(秒) / curl 的连接阶段超时 / 总尝试次数 /
# 首次重试前的等待(秒, 之后翻倍) / 等待上限(秒)
TIMEOUT="60"
CONNECT_TIMEOUT="15"
RETRIES="3"
RETRY_WAIT="5"
RETRY_WAIT_MAX="30"

# 下载时使用的 User-Agent。订阅面板普遍按 UA 决定返回什么: 只认 clash 系
# 客户端的 UA, 不认识的 UA (curl/wget 的默认值、浏览器 UA) 一律 404, 即使
# 链接本身完全有效。实测 (cdn.weatherinformations.com): clash.meta -> 200,
# curl 默认 UA -> 404。所以这里必须显式带一个 clash 系 UA; 用 mihomo 的
# 上游名而不是带版本号的写法, 免得随版本漂移。
USER_AGENT="clash.meta"

# A top level key line, used to find where a top level block ends. Sub items of
# a block are either indented or start with "- " (both styles are common in
# clash profiles), so "the next top level key" is the only reliable end marker.
TOPKEY_RE='^[A-Za-z_][A-Za-z0-9_.-]*[[:space:]]*:'

TMPFILES=""

cleanup() {
	[ -n "$TMPFILES" ] && rm -f $TMPFILES
	return 0
}
trap cleanup EXIT INT TERM

usage() {
	cat <<EOF
Usage: $0 import <url> [name] [force]
       $0 update <name> [url]
       $0 help

  import  url     remote profile URL (http/https)
          name    target file name inside the work directory; defaults to a
                  name derived from the URL, a .yaml suffix is appended when
                  missing
          force   overwrite the target if it already exists

  update  name    existing profile whose "proxies" and "proxy-groups" sections
                  should be refreshed
          url     subscription URL; when omitted the URL recorded for that
                  profile (see <workdir>/sources) is used

Everything downloaded is validated with "mihomo -t" before it replaces
anything on disk. "update" only touches the "proxies" and "proxy-groups"
sections: every other setting in the local file, including manual edits, is
left untouched. If those two sections turn out to be identical to what is
already in the file, nothing is written at all and mihomo is not restarted;
otherwise the file is updated and mihomo is restarted so that the new servers
take effect immediately. The last line of the output is a machine readable
"RESULT: unchanged|updated|updated-restarted" marker.
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

	SOURCES="$WORKDIR/sources"
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

# ---------------------------------------------------------------------------
# 订阅链接记录 (<workdir>/sources)
#
# 每行 "<配置文件名> <URL>", 只在提供了 URL 时写入。文件里可能含订阅凭据,
# 因此权限 0600。
# ---------------------------------------------------------------------------

source_get() {
	[ -f "$SOURCES" ] || return 0
	awk -v n="$1" '$1 == n { sub(/^[^[:space:]]+[[:space:]]+/, ""); print; exit }' "$SOURCES" 2>/dev/null
}

source_set() {
	local n="$1" u="$2" t

	t="$WORKDIR/.sources.$$"

	if [ -f "$SOURCES" ]; then
		awk -v n="$n" '$1 != n' "$SOURCES" > "$t" || { rm -f "$t"; return 1; }
	else
		: > "$t" || return 1
	fi

	printf '%s %s\n' "$n" "$u" >> "$t" || { rm -f "$t"; return 1; }

	chmod 600 "$t" 2>/dev/null
	mv -f "$t" "$SOURCES" || return 1
}

# ---------------------------------------------------------------------------
# 下载
#
# 工具优先级: curl -> wget -> uclient-fetch。
#   curl    控制最细 (连接超时/整体超时/HTTP 状态码), 且自带 TLS 与 CA 依赖,
#           是包依赖里声明的主工具
#   wget    通常由 busybox 提供 (无 TLS), 或由 wget-ssl/uclient-fetch 的
#           alternatives 提供; 只用到 -T/-O, 三个实现都接受
#   uclient- 最后的兜底, 功能最弱
#     fetch
#
# 失败会重试: 每次重试前等待 RETRY_WAIT 秒并翻倍 (5 -> 10 -> 20, 上限
# RETRY_WAIT_MAX)。服务器明确拒绝的错误 (4xx 除 408/429) 与证书问题重试也
# 不会变好, 直接放弃, 不浪费时间。
#
# 刻意不加 quiet 开关: uclient-fetch 的 "HTTP error N" 与 "Connection error:
# ..." 只在非 quiet 时打印 (uclient-fetch.c 两个分支都有 if (!quiet)),
# 而这些正是判断失败原因所需要的行。
# ---------------------------------------------------------------------------

# HTTP 状态码: uclient-fetch 打 "HTTP error 404", busybox wget 打
# "server returned error: HTTP/1.1 404 ...", curl 打 "returned error: 404"。
http_status() {
	sed -n \
		-e 's/.*HTTP error \([0-9][0-9]*\).*/\1/p' \
		-e 's/.*HTTP\/1\.[01] \([0-9][0-9]*\).*/\1/p' \
		-e 's/.*error: \([0-9][0-9][0-9]\).*/\1/p' \
		"$1" | head -n 1
}

fetch_tool() {
	if command -v curl >/dev/null 2>&1; then
		echo curl
	elif command -v wget >/dev/null 2>&1; then
		echo wget
	elif command -v uclient-fetch >/dev/null 2>&1; then
		echo uclient-fetch
	fi
}

fetch_once() {
	local tool="$1" url="$2" out="$3" log="$4"

	case "$tool" in
		curl)
			curl -fsSL -sS -A "$USER_AGENT" --connect-timeout "$CONNECT_TIMEOUT" \
				--max-time "$TIMEOUT" -o "$out" "$url" >"$log" 2>&1 ;;
		wget)
			# -U 在 busybox wget 与 GNU wget 上都是 user-agent
			wget -T "$TIMEOUT" -U "$USER_AGENT" -O "$out" "$url" >"$log" 2>&1 ;;
		*)
			# uclient-fetch 没有自定义 UA 的选项, 发的是它自己的默认 UA;
			# 只认 clash 系 UA 的面板在这种工具下拿不到订阅, 只能换 curl。
			uclient-fetch -T "$TIMEOUT" -O "$out" "$url" >"$log" 2>&1 ;;
	esac
}

# 这次失败是否值得重试
is_retriable() {
	local code

	code=$(http_status "$1")
	if [ -n "$code" ]; then
		case "$code" in
			408|429|5*) return 0 ;;   # 超时/限流/服务端故障: 值得重试
			*)          return 1 ;;   # 其它 4xx: 链接或权限问题, 重试无用
		esac
	fi

	if grep -qiE 'SSL (verify )?error|Invalid SSL certificate|hostname does not match|SSL certificate problem' "$1"; then
		return 1                          # 证书问题重试也不会变
	fi

	return 0
}

# 下载 $url 到 $out, 工具输出写进 $log (只保留最后一次)。
# 重试过程打印到 stdout, 便于在页面上看到; 最终失败原因放在 FETCH_REASON。
fetch() {
	local url="$1" out="$2" log="$3"
	local tool attempt wait reason

	FETCH_REASON=""

	tool=$(fetch_tool)
	[ -n "$tool" ] || die "未找到可用的下载工具 (curl / wget / uclient-fetch)"

	attempt=1
	wait="$RETRY_WAIT"

	while [ "$attempt" -le "$RETRIES" ]; do
		rm -f "$out"

		if fetch_once "$tool" "$url" "$out" "$log"; then
			if [ -s "$out" ]; then
				[ "$attempt" -gt 1 ] && echo "第 $attempt 次尝试成功 (工具: $tool)"
				return 0
			fi
			reason="服务器返回了空内容 (0 字节)"
		else
			reason=$(fetch_reason "$log" "$url")
		fi
		FETCH_REASON="$reason"

		echo "第 $attempt 次尝试失败: $reason"

		if [ "$attempt" -ge "$RETRIES" ]; then
			break
		fi

		if ! is_retriable "$log"; then
			echo "这类错误重试也不会成功, 不再重试。"
			return 1
		fi

		echo "等待 ${wait}s 后重试 (第 $((attempt + 1))/$RETRIES 次)…"
		sleep "$wait"

		wait=$((wait * 2))
		[ "$wait" -gt "$RETRY_WAIT_MAX" ] && wait="$RETRY_WAIT_MAX"

		attempt=$((attempt + 1))
	done

	return 1
}

# Host part of a URL (scheme/userinfo/path/port stripped).
url_host() {
	printf '%s' "$1" | sed -e 's#^[A-Za-z][A-Za-z0-9+.-]*://##' -e 's#[/?#].*$##' -e 's#^.*@##' -e 's#:[0-9]*$##'
}

# Can $1 be resolved? Probed with nslookup/ping; when neither exists we report
# "resolvable" so that an undecidable case is never blamed on DNS.
host_resolves() {
	[ -n "$1" ] || return 0

	if command -v nslookup >/dev/null 2>&1; then
		nslookup "$1" >/dev/null 2>&1
	elif command -v ping >/dev/null 2>&1; then
		ping -c 1 -W 2 "$1" >/dev/null 2>&1
	else
		return 0
	fi
}

# Lines worth showing from the download log; the normal progress output
# ("Downloading '...'", "Connecting to ...", "Download completed") is dropped.
log_hints() {
	grep -iE 'error|fail|refus|timed out|timeout|unable|invalid|resolve|bad address|SSL|certificate|reset|redirect' "$1" 2>/dev/null | head -n 12
}

# Turn the download log into one Chinese sentence naming the cause. The wording
# covers uclient-fetch, busybox wget and curl.
fetch_reason() {
	local log="$1" url="$2" host code

	host=$(url_host "$url")

	code=$(http_status "$log")
	if [ -n "$code" ]; then
		case "$code" in
			401|403|407) echo "HTTP $code: 订阅地址被服务器拒绝, 链接可能已失效或需要重新获取" ;;
			404|410)     echo "HTTP $code: 订阅地址不存在, 链接可能已更换" ;;
			429)         echo "HTTP 429: 请求过于频繁, 被订阅服务器限流" ;;
			4*)          echo "HTTP $code: 请求被服务器拒绝" ;;
			5*)          echo "HTTP $code: 订阅服务器内部错误, 可稍后重试" ;;
			*)           echo "订阅服务器返回 HTTP 错误状态" ;;
		esac
		return
	fi

	if grep -qiE 'SSL (verify )?error|Invalid SSL certificate|hostname does not match|SSL certificate problem|certificate' "$log"; then
		echo "TLS/证书错误: 无法与 $host 建立可信连接 (证书无效或路由器时间不正确)"
		return
	fi

	if grep -qiE 'timed out|timeout' "$log"; then
		if host_resolves "$host"; then
			echo "连接超时: $host 能解析但连接超时 (线路不通或该地址被阻断)"
		else
			echo "域名解析失败: 无法解析 $host, 随后连接超时"
		fi
		return
	fi

	if grep -qiE 'Connection failed|Connection refused|Connection reset|can.t connect|Failed to connect|Network is unreachable|bad address|Could not resolve|resolve host' "$log"; then
		if grep -qiE 'bad address|Could not resolve|resolve host' "$log"; then
			echo "域名解析失败: 无法解析 $host (DNS 查询失败, 请检查路由器的 DNS)"
		elif host_resolves "$host"; then
			echo "网络连接失败: $host 能解析但无法建立连接 (端口被拒绝或被阻断, 或该地址需经代理访问)"
		else
			echo "域名解析失败: 无法解析 $host (DNS 查询失败, 请检查路由器的 DNS)"
		fi
		return
	fi

	echo "下载失败, 未能从下载工具的输出中识别具体原因"
}

# 判断订阅是否被上游返回成了网页 (常见于链接过期后跳到登录页/错误页)
looks_like_html() {
	head -c 1024 "$1" 2>/dev/null | grep -qiE '<!DOCTYPE|<html|<head|<body'
}

# ---------------------------------------------------------------------------
# 订阅格式规范化
#
# 订阅链接返回的内容并不总是「明文 YAML」, 常见的有:
#   1. 明文 YAML                    <- 正常情况
#   2. gzip 压缩的 YAML             <- 少数服务器无视 Accept-Encoding 直接压
#   3. base64 编码的 YAML           <- 部分机场对所有订阅统一 base64
#   4. base64 编码的节点链接列表     <- 这是 v2ray/ss 客户端的订阅格式, 不是
#      (ss:// vmess:// trojan:// …)     clash 配置, 必须换成 Clash 订阅地址
#   5. 网页 (登录页 / 错误页)
#
# 1/2/3 都能继续处理, 4/5 直接给出可读原因, 不让它们变成晦涩的 YAML 报错。
# ---------------------------------------------------------------------------

# gzip 魔数 1f 8b
is_gzip() {
	[ -s "$1" ] || return 1
	head -c 2 "$1" 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \n' | grep -q '^1f8b'
}

looks_like_yaml() {
	grep -qE "$TOPKEY_RE" "$1" 2>/dev/null
}

# 去掉空白后整段都是 base64 字符集
looks_like_base64() {
	[ -s "$1" ] || return 1
	tr -d '\r\n \t' < "$1" 2>/dev/null | grep -qE '^[A-Za-z0-9+/]+=*$'
}

# 节点链接列表 (v2ray/ss 系订阅)
looks_like_node_list() {
	grep -qE '^(ss|ssr|vmess|vless|trojan|hysteria|hysteria2|hy2|tuic|socks5?|http)://' "$1" 2>/dev/null
}

decode_base64() {
	if command -v base64 >/dev/null 2>&1; then
		base64 -d "$1" 2>/dev/null > "$2"
	elif command -v openssl >/dev/null 2>&1; then
		openssl base64 -d -in "$1" -out "$2" 2>/dev/null
	else
		return 1
	fi

	[ -s "$2" ]
}

# 把下载到的内容规整成可解析的 YAML 写进 $2; $3 是错误消息的前缀。
prepare_payload() {
	local raw="$1" out="$2" prefix="$3" dec

	if is_gzip "$raw"; then
		if command -v gzip >/dev/null 2>&1; then
			gzip -dc "$raw" > "$out" 2>/dev/null
		elif command -v zcat >/dev/null 2>&1; then
			zcat "$raw" > "$out" 2>/dev/null
		fi

		[ -s "$out" ] || die "$prefix: 订阅返回了 gzip 压缩内容, 但系统里没有可用的解压工具 (gzip)"
		echo "订阅内容为 gzip 压缩, 已自动解压"
	else
		cp -f "$raw" "$out" || die "$prefix: 无法读取下载到的内容"
	fi

	if looks_like_html "$out"; then
		die "$prefix: 订阅返回的是网页而不是配置文件 (链接可能已失效, 或需要先登录再获取订阅)"
	fi

	if ! looks_like_yaml "$out" && looks_like_base64 "$out"; then
		dec="/tmp/mihomo-payload.$$.decoded"
		TMPFILES="$TMPFILES $dec"

		if decode_base64 "$out" "$dec"; then
			cp -f "$dec" "$out"
			echo "订阅内容为 base64 编码, 已自动解码"
		fi
	fi

	if looks_like_node_list "$out"; then
		die "$prefix: 订阅返回的是节点链接列表 (ss:// vmess:// trojan:// …), 不是 clash/mihomo 配置
提示: 这是给 v2ray / Shadowsocks 客户端用的订阅格式。请改用机场提供的 Clash 订阅地址 (常见做法是在订阅链接后加 \&flag=clash), 或者改用 proxy-providers 引用它。"
	fi

	if ! looks_like_yaml "$out"; then
		die "$prefix: 订阅内容不是 YAML 配置 (没有找到任何顶层配置段)
前 200 字节: $(head -c 200 "$out" 2>/dev/null | tr '\n' ' ')"
	fi
}

# ---------------------------------------------------------------------------
# 校验
# ---------------------------------------------------------------------------

# Run the upstream validator on a candidate file, mirroring the invocation of
# /etc/init.d/mihomo ("-f <config> -d <workdir>"). Prints the validator output
# and returns its exit code. mihomo logs to stdout (log.SetOutput(os.Stdout)),
# so the diagnostics of a failed check appear on stdout, not on stderr.
check_file() {
	"$PROG" -t -f "$1" -d "$WORKDIR" 2>&1
}

# Explain the most common mihomo -t failures in Chinese. The messages matched
# here come from mihomo's config parser (config/config.go):
#   "rules[N] [line] error: proxy [X] not found"        -> rules 引用了不存在的代理/组
#   "proxy-groups[N] [line] error: proxy [X] not found" -> 代理组引用了不存在的代理
check_hint() {
	if grep -qE 'proxy \[[^]]*\] not found' "$1"; then
		echo "本地有段落引用了远程配置里不存在的代理或代理组 (报错中的 proxy [xxx] not found)。"
		echo "常见原因: 订阅里的代理组名称发生了变化, 或远程只剩 proxy-providers 而没有内联 proxies。"
		echo "可对比本地 rules 段引用的组名与远程 proxy-groups 里的组名。"
	elif grep -qiE 'yaml: |unmarshal|cannot unmarshal' "$1"; then
		echo "合并后的内容不是有效 YAML, 说明本地文件中这两段的结构与预期不同 (例如使用了 YAML 锚点别名, 或该段被写在其它键之下)。"
		echo "建议在编辑区里手动检查这两段, 或改用整份导入。"
	elif grep -qiE 'error|invalid' "$1"; then
		echo "mihomo 在处理合并后的配置时报告了错误, 详情见上方输出。"
	fi
}

# ---------------------------------------------------------------------------
# YAML 顶层块处理
#
# clash/mihomo 的每个顶层键都是一条独立的块。块内子项要么缩进, 要么与键行同列
# 以 "- " 开头, 所以「遇到下一个顶层键」才是块结束的可靠判据 (不能按缩进回退来
# 判断)。列表项 "- xxx" 与注释 "# xxx" 都不匹配顶层键模式, 不会被误判。
# ---------------------------------------------------------------------------

block_range() {
	# $1=文件 $2=键名 -> 输出 "起始行 结束行"; 没有该键时不输出任何内容
	awk -v key="$2" -v topre="$TOPKEY_RE" '
		function iskey(line, k) {
			if (substr(line, 1, length(k)) != k)
				return 0
			return substr(line, length(k) + 1) ~ /^[[:space:]]*:/
		}
		!inblk && iskey($0, key) {
			start = NR; end = NR; inblk = 1; found = 1
			rest = $0
			sub(/^[^:]*:/, "", rest)
			gsub(/^[[:space:]]+|[[:space:]]+$/, "", rest)
			if (rest != "" && rest !~ /^#/)
				inblk = 0          # 内联形式 (proxies: [] / proxies: [{...}])
			next
		}
		inblk {
			if ($0 ~ topre) { inblk = 0; next }
			if ($0 ~ /^[[:space:]]*$/) next   # 尾部空行归原文, 不并入块
			end = NR
		}
		END { if (found) print start, end }
	' "$1"
}

block_exists() {
	[ -n "$(block_range "$1" "$2")" ]
}

# 把整个块 (含键行, 不含尾部空行) 写到 stdout; 没有该块时返回 1
extract_block() {
	local file="$1" key="$2" r from to

	r=$(block_range "$file" "$key")
	[ -n "$r" ] || return 1

	from="${r%% *}"
	to="${r##* }"
	sed -n "${from},${to}p" "$file"
}

# 判断一个块文件里是否真的有条目 (空列表 proxies: [] 视为空)
block_has_entries() {
	grep -qE '^[[:space:]]*-[[:space:]]*[^[:space:]]' "$1" && return 0
	grep -qE '^[^:]+:[[:space:]]*\[[[:space:]]*[^]]' "$1" && return 0
	return 1
}

# 用新块替换 $1 里的对应段; 本地没有该段时追加到文件末尾。结果写 stdout。
replace_block() {
	local file="$1" blk="$2" key="$3" r from to

	r=$(block_range "$file" "$key")

	if [ -z "$r" ]; then
		cat "$file"
		[ -n "$(tail -c 1 "$file" 2>/dev/null)" ] && echo
		echo
		cat "$blk"
	else
		from="${r%% *}"
		to="${r##* }"
		[ "$from" -gt 1 ] && head -n $((from - 1)) "$file"
		cat "$blk"
		tail -n +$((to + 1)) "$file"
	fi
}

# 归一化后的内容, 只用于比较, 不改写文件本身: 去掉行尾空白、空行与整行注释。
# 订阅里常见的「更新时间」注释行每次都会有细微差别, 不剔除的话每天都会被判成
# 「有变化」而白白重启一次代理, 而这些差异对 mihomo 来说没有任何意义。
# 只剔除整行注释 (行首可选空白 + #), 不碰行内注释, 避免误伤值里含 # 的条目。
normalize_file() {
	sed -e 's/[[:space:]]*$//' -e '/^[[:space:]]*$/d' -e '/^[[:space:]]*#/d' "$1"
}

# ---------------------------------------------------------------------------
# 命令: import
# ---------------------------------------------------------------------------

do_import() {
	local url="$1" name="$2" force="$3" target dl norm flog stage hints reason

	[ -n "$url" ] || die "缺少 URL"

	case "$url" in
		http://*|https://*) ;;
		*) die "只支持 http:// 与 https:// 开头的 URL" ;;
	esac

	[ -n "$name" ] || name="$(name_from_url "$url")"
	normalize_name "$name"
	name="$NAME"

	[ -x "$PROG" ] || die "mihomo 主程序不存在: $PROG"

	target="$WORKDIR/$name"

	if [ -e "$target" ] && [ "$force" != "force" ]; then
		die "$target 已存在 (如需覆盖请在页面上勾选\"覆盖同名文件\")"
	fi

	mkdir -p "$WORKDIR" || die "无法创建目录 $WORKDIR"

	# Download and validate in /tmp: the candidate must never appear in the
	# work directory before it passed the check, and /tmp avoids flash writes.
	dl="/tmp/mihomo-import.$$.yaml"
	flog="/tmp/mihomo-import.$$.log"
	TMPFILES="$TMPFILES $dl $flog"

	echo "== 下载 =="
	echo "URL:  $url"
	echo "目标: $target"
	echo

	if ! fetch "$url" "$dl" "$flog"; then
		hints=$(log_hints "$flog")
		echo "-- 最后一次的下载日志 --"
		if [ -n "$hints" ]; then echo "$hints"; else tail -n 6 "$flog" 2>/dev/null; fi
		echo
		echo "原因: $FETCH_REASON"
		echo
		die "导入 $name 失败: $FETCH_REASON"
	fi

	[ -s "$dl" ] || die "导入 $name 失败: 订阅返回 0 字节内容 (订阅可能已过期或链接已失效)"

	echo "已下载 $(wc -c < "$dl" | tr -d ' ') 字节"

	# 订阅不一定直接给明文 YAML (可能 gzip 压缩 / base64 编码 / 甚至误给网页或
	# 节点链接列表), 统一规整成明文 YAML 后再送去校验。
	norm="/tmp/mihomo-import.$$.norm"
	TMPFILES="$TMPFILES $norm"
	prepare_payload "$dl" "$norm" "导入 $name 失败"
	dl="$norm"
	echo

	echo "== 校验 (mihomo -t) =="
	if ! check_file "$dl"; then
		echo
		die "导入 $name 失败: 配置未通过 mihomo -t 校验, 未写入 $target"
	fi
	echo

	# Rename within the same directory so the target is either the old or the
	# new file, never a half written one. 0600 matches INSTALL_CONF.
	stage="$WORKDIR/.$name.$$"
	TMPFILES="$TMPFILES $stage"
	cp -f "$dl" "$stage" || die "导入 $name 失败: 写入暂存文件失败 ($stage)"
	chmod 600 "$stage"
	if ! mv -f "$stage" "$target"; then
		die "导入 $name 失败: 替换 $target 失败"
	fi

	echo "== 完成 =="
	echo "已导入: $target"

	if source_set "$name" "$url"; then
		echo "已记录订阅链接, 之后可用「仅更新服务器和代理组」单独刷新"
	fi

	if [ "$target" = "$CONFFILE" ]; then
		echo "该文件正是当前生效的配置, 重启 mihomo 服务后生效。"
	else
		echo "当前生效的配置是 $CONFFILE"
		echo "如需使用新配置, 请在页面上选中它并点击\"设为当前配置并重启\"。"
	fi
}

# ---------------------------------------------------------------------------
# 命令: update  (只替换 proxies / proxy-groups 两段, 其余内容原样保留)
# ---------------------------------------------------------------------------

do_update() {
	local name="$1" url="$2" from_record=0
	local target before after cur stage
	local dl norm flog newp newg m1 m2 chk rc hints reason
	local have_p have_g n1 n2 note_p note_g

	[ -n "$name" ] || die "缺少配置文件名"

	normalize_name "$name"
	name="$NAME"

	target="$WORKDIR/$name"

	[ -f "$target" ] || die "更新 $name 失败: 配置文件不存在 ($target, 仅更新只能作用于已存在的配置)"

	if [ -z "$url" ]; then
		url="$(source_get "$name")"
		from_record=1
		if [ -z "$url" ]; then
			die "更新 $name 失败: 该配置没有记录订阅链接, 请在「仅更新服务器和代理组」的输入框里填写链接后重试"
		fi
	fi

	case "$url" in
		http://*|https://*) ;;
		*) die "只支持 http:// 与 https:// 开头的 URL" ;;
	esac

	[ -x "$PROG" ] || die "mihomo 主程序不存在: $PROG"

	dl="/tmp/mihomo-update.$$.yaml"
	flog="/tmp/mihomo-update.$$.log"
	newp="/tmp/mihomo-update.$$.proxies"
	newg="/tmp/mihomo-update.$$.groups"
	m1="/tmp/mihomo-update.$$.1"
	m2="/tmp/mihomo-update.$$.2"
	chk="/tmp/mihomo-update.$$.check"
	n1="/tmp/mihomo-update.$$.cmp.new"
	n2="/tmp/mihomo-update.$$.cmp.old"
	TMPFILES="$TMPFILES $dl $flog $newp $newg $m1 $m2 $chk $n1 $n2"

	before=$(wc -c < "$target" | tr -d ' ')

	echo "== 目标 =="
	echo "配置: $target"
	echo "来源: $url"
	[ "$from_record" = 1 ] && echo "(来源为导入时记录的订阅链接)"
	echo

	echo "== 下载 =="
	if ! fetch "$url" "$dl" "$flog"; then
		hints=$(log_hints "$flog")
		echo "-- 最后一次的下载日志 --"
		if [ -n "$hints" ]; then echo "$hints"; else tail -n 6 "$flog" 2>/dev/null; fi
		echo
		echo "原因: $FETCH_REASON"
		echo
		die "更新 $name 失败: $FETCH_REASON"
	fi

	[ -s "$dl" ] || die "更新 $name 失败: 订阅返回 0 字节内容 (订阅可能已过期或链接已失效)"

	echo "已下载 $(wc -c < "$dl" | tr -d ' ') 字节"

	# 先规整成明文 YAML 再提取, 否则 gzip / base64 订阅会被当成"没有 proxies 段"。
	norm="/tmp/mihomo-update.$$.norm"
	TMPFILES="$TMPFILES $norm"
	prepare_payload "$dl" "$norm" "更新 $name 失败"
	dl="$norm"
	echo

	echo "== 提取 (远程配置) =="
	have_p=0
	have_g=0

	if extract_block "$dl" proxies > "$newp"; then
		have_p=1
		echo "proxies:       $(wc -l < "$newp" | tr -d ' ') 行"
	else
		echo "proxies:       未找到"
	fi

	if extract_block "$dl" proxy-groups > "$newg"; then
		have_g=1
		echo "proxy-groups:  $(wc -l < "$newg" | tr -d ' ') 行"
	else
		echo "proxy-groups:  未找到"
	fi
	echo

	if [ "$have_p" = 0 ] && [ "$have_g" = 0 ]; then
		die "更新 $name 失败: 远程配置里既没有 proxies 也没有 proxy-groups 段 (可能不是 clash/mihomo 订阅, 或订阅内容被上游改写)"
	fi

	if [ "$have_p" = 1 ] && ! block_has_entries "$newp"; then
		die "更新 $name 失败: 远程 proxies 段为空列表, 拒绝用它覆盖本地的服务器列表"
	fi

	# 先静默算一遍合并结果, 与磁盘上的文件比较之后再决定要不要动它。
	# 内容一致时连写盘都不做: 文件时间戳不变, 服务也就不会因为「配置文件被
	# 改过」而被 procd 的 file 检查判成需要重启, 代理不会白闪一次。
	cur="$target"
	note_p=""
	note_g=""

	if [ "$have_p" = 1 ]; then
		if block_exists "$cur" proxies; then
			note_p="已用远程内容替换"
		else
			note_p="本地原本没有该段, 已追加到文件末尾"
			if grep -qE '^proxy-providers:' "$cur"; then
				note_p="$note_p
               (注意: 本地使用了 proxy-providers, 追加内联 proxies 后两者会同时生效)"
			fi
		fi
		replace_block "$cur" "$newp" proxies > "$m1" || die "更新 $name 失败: 处理 proxies 段时出错"
		cur="$m1"
	else
		note_p="远程没有该段, 保持本地不变"
	fi

	if [ "$have_g" = 1 ]; then
		if block_exists "$cur" proxy-groups; then
			note_g="已用远程内容替换"
		else
			note_g="本地原本没有该段, 已追加到文件末尾"
		fi
		replace_block "$cur" "$newg" proxy-groups > "$m2" || die "更新 $name 失败: 处理 proxy-groups 段时出错"
		cur="$m2"
	else
		note_g="远程没有该段, 保持本地不变"
	fi

	echo "== 对比 =="
	normalize_file "$cur" > "$n1"
	normalize_file "$target" > "$n2"

	if cmp -s "$n1" "$n2"; then
		echo "远程的 proxies / proxy-groups 与本地一致, 没有新内容。"
		echo "未改动 $target, 也不会重启服务。"
		echo
		echo "RESULT: unchanged"

		if [ "$from_record" = 0 ]; then
			source_set "$name" "$url" \
				&& echo "已记录本次使用的订阅链接, 下次可直接点「仅更新」无需再填写"
		fi
		return 0
	fi

	echo "有内容变化, 将替换下面这两段 (其余内容原样保留):"
	echo "proxies:       $note_p"
	echo "proxy-groups:  $note_g"
	echo

	echo "== 校验 (mihomo -t) =="
	check_file "$cur" > "$chk" 2>&1
	rc=$?
	cat "$chk"
	echo

	if [ "$rc" -ne 0 ]; then
		echo "-- 失败原因提示 --"
		check_hint "$chk"
		echo
		die "更新 $name 失败: 合并后的配置未通过 mihomo -t 校验 (退出码 $rc), 未修改 $target"
	fi

	echo "== 写入 =="
	stage="$WORKDIR/.$name.$$"
	TMPFILES="$TMPFILES $stage"

	cp -f "$cur" "$stage" || die "更新 $name 失败: 写入暂存文件失败 ($stage)"

	mode=$(stat -c '%a' "$target" 2>/dev/null)
	[ -n "$mode" ] && chmod "$mode" "$stage" 2>/dev/null

	if ! mv -f "$stage" "$target"; then
		die "更新 $name 失败: 替换 $target 失败"
	fi

	after=$(wc -c < "$target" | tr -d ' ')

	echo "已更新: $target ($before -> $after 字节)"
	echo "其他段落 (rules / dns / tun 等) 未做任何改动"
	echo

	if [ "$from_record" = 0 ]; then
		if source_set "$name" "$url"; then
			echo "已记录本次使用的订阅链接, 下次可直接点「仅更新」无需再填写"
		fi
	fi

	if [ "$target" != "$CONFFILE" ]; then
		echo "当前生效的配置是 $CONFFILE, 本次更新的不是它, 因此不重启服务。"
		echo "RESULT: updated"
		return 0
	fi

	# 只有更新的是当前生效的配置, 重启才有意义 —— 更新别的文件时重启服务只会
	# 把正在工作的代理打断。服务没在运行时也不去拉它, 免得「更新订阅」顺手把
	# 服务的运行状态改掉 (uci mihomo.main.enabled = 0 时 start_service 会直接
	# 返回, 重启也不会真的拉起进程)。
	if [ ! -x "$INITD" ]; then
		echo "提示: 找不到 $INITD, 请手动重启 mihomo 让新配置生效。" >&2
		echo "RESULT: updated"
		return 0
	fi

	if ! "$INITD" running >/dev/null 2>&1; then
		echo "mihomo 服务当前没有运行, 未执行重启 (下次启动时会使用新配置)。"
		echo "RESULT: updated"
		return 0
	fi

	echo "== 重启 =="
	if "$INITD" restart; then
		echo "已重启 mihomo 服务, 新配置已生效。"
		echo "RESULT: updated-restarted"
	else
		echo "错误: 配置已更新, 但 mihomo 服务重启失败 (详见上面的输出与系统日志)" >&2
		echo "RESULT: restart-failed"
		exit 1
	fi
}

cmd="$1"
[ $# -gt 0 ] && shift

case "$cmd" in
	import)
		load_config
		do_import "$1" "$2" "$3"
		;;
	update)
		load_config
		do_update "$1" "$2"
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

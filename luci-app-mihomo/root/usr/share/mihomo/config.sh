#!/bin/bash
# mihomo configuration manager.
#
#   config.sh import <url> [name] [force]   download a remote clash/mihomo
#                                           profile, validate it and install
#                                           it into the work directory
#   config.sh install <src> <name>          validate a file that was staged in
#                                           /tmp (the LuCI page writes edited
#                                           configs there in small chunks) and
#                                           install it into the work directory
#   config.sh update <name> [url]           re-download the subscription and
#                                           replace ONLY the "proxies" and
#                                           "proxy-groups" sections of an
#                                           existing profile. When the remote
#                                           sections are identical to the local
#                                           ones nothing is written and the
#                                           service is left alone; when they
#                                           differ the file is updated and
#                                           mihomo is restarted.
#   config.sh remove <name>                 delete a profile from the work
#                                           directory and drop its recorded
#                                           subscription URL. The live config
#                                           (uci mihomo.main.conffile) is
#                                           always refused; switch to another
#                                           profile first.
#   config.sh help
#
# Only the network facing part lives here plus the "install" step for edited
# files; the LuCI "配置文件" page handles listing, reading and editing directly
# through the rpcd file API, stages the edited content in /tmp in small chunks
# (a single large request body kills nginx's ubus module) and then calls
# "config.sh install" to validate and atomically install it.
#
# The work directory and the config file name are read from /etc/config/mihomo
# so that this script always agrees with /etc/init.d/mihomo.
#
# Subscription URLs are remembered in <workdir>/sources ("<name> <url>" per
# line, mode 0600) so that "update" can be re-run without retyping the URL.

[ -s /lib/functions.sh ] && . /lib/functions.sh

PROG="/usr/bin/mihomo"
INITD="/etc/init.d/mihomo"
# 随包发布的配置模版 (转换目标: proxy-groups / rules / rule-providers)。
# 用户自建模版放 <workdir>/templates/, 两处都出现在 LuCI 的模版下拉里。
TPL_BUILTIN="/usr/share/mihomo/templates"

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
       $0 install <src> <name>
       $0 update <name> [url]
       $0 remove <name>
       $0 help

  import  url     remote profile URL (http/https)
          name    target file name inside the work directory; defaults to a
                  name derived from the URL, a .yaml suffix is appended when
                  missing
          force   overwrite the target if it already exists

  install src     path of an already assembled profile outside the work
                  directory (the LuCI "配置文件" page stages edited content in
                  /tmp and uploads it in small chunks, because a single large
                  request body kills nginx's ubus module)
          name    target file name inside the work directory; the target is
                  replaced

  update  name    existing profile whose "proxies" section should be refreshed
                  from the subscription. Everything else (proxy-groups, rules,
                  dns, manual edits) stays local: it is the authoritative
                  version. When the profile is bound to a template (see below)
                  proxy-groups / rules / rule-providers are rewritten from that
                  template first, then custom groups are appended.
          url     subscription URL; when omitted the URL recorded for that
                  profile (see <workdir>/sources) is used

  template list           list available templates: "id<TAB>description".
          show <id>       print a template file
          apply <name> <id>
                          convert profile <name> with template <id> right now
                          (proxies untouched, no subscription download)
          bind <name> <id>
                          bind <name> to template <id> ("-" clears) via
                          uci mihomo.main.template_map; a bound profile has
                          its groups/rules rewritten from the template on
                          every "update"

  Template sources: /usr/share/mihomo/templates (bundled, id prefix
  "builtin:") and <workdir>/templates (user made, id prefix "user:"). A
  template is NOT a runnable config: it describes the conversion target —
  template-info (name/desc/adapter), proxy-groups, rules, optional
  rule-providers. The converter keeps the profile's servers and every other
  section, replaces those blocks, and rewrites the dns nameserver "#group"
  suffixes to the template's adapter group so the DNS egress stays pinned.

  custom-save stage
                  install a staged file (/tmp/mihomo-config-upload.*) as
                  <workdir>/custom.d/custom-groups.yaml. That file holds
                  the user's own proxy groups; after a template conversion
                  ("update" of a bound profile or "template apply") they are
                  appended to the converted groups, same-name template groups
                  win. Profiles listed in the uci list
                  mihomo.main.custom_groups_off are skipped.

  override-save <name> <stage>
                  install a staged file (/tmp/...) as
                  <workdir>/overrides/<name>.yaml — the per-profile override
                  (Clash Verge "Merge" style). Top-level keys: "<key>" replaces
                  that whole block; "prepend-<key>" / "append-<key>" insert
                  items at the front / back of that list. The override is the
                  last layer applied by both "update" and "template apply",
                  above templates and custom groups. An empty staged file
                  clears (disables) the override.

  remove  name    profile to delete from the work directory. The currently
                  selected config (uci mihomo.main.conffile) is refused; its
                  recorded subscription URL is dropped as well. When the
                  scheduled update targets this profile a warning is printed
                  (the cron job would fail on the next run until the target
                  is changed or the schedule is disabled).

Everything downloaded or staged is validated with "mihomo -t" before it
replaces anything on disk, and the replacement happens through a rename inside
the work directory, so the target file is either the old or the new one and
never a half written one. "update" only replaces the "proxies" section (plus
the template conversion described above): every other setting in the local
file, including manual edits, is left untouched. If the result turns out to be
identical to what is already in the file, nothing is written at all and mihomo
is not restarted; otherwise the file is updated and mihomo is restarted so
that the new servers take effect immediately. The last line of the output is a
machine readable "RESULT: unchanged|updated|updated-restarted|applied|
applied-restarted|bound" marker.
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
	CUSTOM_OFF=""
	TEMPLATE_MAP=""

	if [ -f /etc/config/mihomo ]; then
		config_load mihomo
		config_get WORKDIR "main" "workdir" "/etc/mihomo"
		config_get CONFFILE "main" "conffile" "/etc/mihomo/config.yaml"
		# 不做自定义组合并的 profile 列表 (LuCI 配置页勾选, 空格分隔)
		config_get CUSTOM_OFF "main" "custom_groups_off"
		# 模版绑定: uci list 元素 "<profile>=<tpl-id>" (config_get 把 list
		# 拼成空格分隔的一行; profile 名与 tpl-id 都不含空格, 可以这样拆)
		config_get TEMPLATE_MAP "main" "template_map"
	fi

	SOURCES="$WORKDIR/sources"
}

# 取某 profile 绑定的模版 id; 没有绑定时返回 1
template_bound() {
	local e
	for e in $TEMPLATE_MAP; do
		[ "${e%%=*}" = "$1" ] && { echo "${e#*=}"; return 0; }
	done
	return 1
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

# ---------------------------------------------------------------------------
# 自定义代理组
#
# 统一入口: $WORKDIR/custom.d/custom-groups.yaml。放在子目录是为了不进
# LuCI 配置文件列表(列表只收 workdir 顶层的 *.yaml)。用户把自定义组(任意
# 类型)写在里面, 对所有 profile 的订阅更新生效, 不随 update 丢失, 换订阅
# 也不用重写。文件内容就是一段 proxy-groups 块:
#   proxy-groups:
#     - { name: 自动测速, type: url-test, proxies: [香港, 东京, 新加坡, 美国],
#         url: 'http://www.gstatic.com/generate_204', interval: 1800, tolerance: 50 }
#
# update 时的合并规则(merge_local_groups):
#   1. 组源 = custom-groups.yaml (权威) + 旧 profile 里已手写的组(向后兼容,
#      同名时 custom-groups.yaml 优先; 用户把组挪进统一文件后旧写法自然失效);
#   2. 按组名判重, 远程已有的组以远程为准;
#   3. 本地独有的组追加到 proxy-groups 段末尾;
#   4. 组名自动补进远程各 select 组的 proxies 列表(流式 [a, b] 与块式逐行均
#      支持), 保留「在手动选择组里挑自定义组」的入口。
# 组切分规则: 列表项以缩进 + "- " 开头, 同级项缩进相同; 更深缩进的 "- x"
# (块式 proxies 子项)、续行、空行、注释都归属当前组, 避免把子项误切成组。
# 本地组引用的子组/节点若在远程已改名, 合并结果过不了 mihomo -t, 更新会
# 中止并提示 — 硬失败优于静默丢组。
# ---------------------------------------------------------------------------

merge_local_groups() {
	local localfile="$1" remotefile="$2" outfile="$3" groups="$4" keptf="$5"
	local custom="$WORKDIR/custom.d/custom-groups.yaml"
	: > "$groups"
	[ -s "$custom" ] && cat "$custom" >> "$groups"
	if block_exists "$localfile" proxy-groups; then
		extract_block "$localfile" proxy-groups >> "$groups"
	fi
	[ -s "$groups" ] || { cp "$remotefile" "$outfile"; echo 0 > "$keptf"; return 0; }
	awk -v localgroups="$groups" -v keptf="$keptf" -v topre="$TOPKEY_RE" '
		function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
		function value1(line, key,   t) {
			t = line
			if (t !~ key "[[:space:]]*:") return ""
			sub("^.*" key "[[:space:]]*:[[:space:]]*", "", t)
			sub(/[,}].*$/, "", t)
			gsub(/[\047\042]/, "", t)
			return trim(t)
		}
		function field(block, key,   L, n, i, v) {
			n = split(block, L, "\n")
			for (i = 1; i <= n; i++) { v = value1(L[i], key); if (v != "") return v }
			return ""
		}
		function last_close(line,   pos, p) {
			pos = 0
			for (;;) {
				p = index(substr(line, pos + 1), "]")
				if (p == 0) break
				pos += p
			}
			return pos
		}
		# 对一个远程 select 组块补入缺失的本地组名; 返回补好的块
		function treat(block,   L, n, i, i2, k, typ, nm, res, newline, t, collecting, lastitem, ins_ind, p, plist, inj, covered, q1, q2, c3) {
			typ = field(block, "type")
			if (typ != "select" || cnt == 0) return block
			nm = field(block, "name")
			n = split(block, L, "\n")
			# 流式内联: proxies: [ ... ] (可能还有后续键, 在最后一个 ] 前插入)
			for (i = 1; i <= n; i++) {
				if (L[i] ~ /proxies:[[:space:]]*\[/ && (p = last_close(L[i])) > 0) {
					plist = substr(L[i], index(L[i], "[") + 1, p - index(L[i], "[") - 1)
					inj = ""
					for (k = 1; k <= cnt; k++) {
						# Never add a select group to its own proxy list; in legacy profile
						# mode the local source also contains the remote select group.
						if (names[k] == nm) continue
						q1 = "\047" names[k] "\047"; q2 = "\042" names[k] "\042"; c3 = "," names[k] ","
						covered = index(L[i], q1) != 0 || index(L[i], q2) != 0 || index(plist, c3) != 0 || index("," plist ",", c3) != 0
						if (!covered) inj = inj (inj == "" ? "" : ", ") "\047" names[k] "\047"
					}
					if (inj == "") return block
					newline = substr(L[i], 1, p - 1) ", " inj "]" substr(L[i], p + 1)
					return join_ins(L, n, i, newline)
				}
			}
			# 块式: proxies: 逐行列表, 在最后一个子项后按同缩进追加
			collecting = 0; lastitem = 0; ins_ind = "  "
			for (i = 1; i <= n; i++) {
				if (collecting) {
					if (L[i] ~ /^[[:space:]]+-[[:space:]]/) {
						lastitem = i
						match(L[i], /^[[:space:]]*/)
						ins_ind = substr(L[i], 1, RLENGTH)
						continue
					}
					if (L[i] ~ /^[[:space:]]*$/ || L[i] ~ /^[[:space:]]*#/) continue
					break
				}
				if (L[i] ~ /^[[:space:]]*proxies:[[:space:]]*$/) collecting = 1
			}
			if (collecting && lastitem > 0) {
				inj = ""
				for (k = 1; k <= cnt; k++) {
					if (names[k] == nm) continue
					covered = 0
					for (i2 = 1; i2 <= n; i2++) {
						if (index(L[i2], "\047" names[k] "\047") != 0 || index(L[i2], "\042" names[k] "\042") != 0) { covered = 1; break }
						if (L[i2] ~ /^[[:space:]]+-[[:space:]]/) {
							t = substr(L[i2], RLENGTH + 1)
							gsub(/[\047\042]/, "", t)
							sub(/[[:space:]]+$/, "", t)
							if (t == names[k]) { covered = 1; break }
						}
					}
					if (!covered) inj = inj (inj == "" ? "" : " ") ins_ind "- \047" names[k] "\047\n"
				}
				if (inj == "") return block
				res = ""
				for (i = 1; i <= n; i++) {
					res = res L[i] "\n"
					if (i == lastitem) { res = res inj; i = n + 1; break }
				}
				return res
			}
			return block
		}
		function join_ins(L, n, at, newline,   i, res) {
			res = ""
			for (i = 1; i <= n; i++) {
				res = res (i == at ? newline : L[i]) (i < n ? "\n" : "")
			}
			return res
		}
		function flush_group() {
			if (cur == "") return
			nm = field(cur, "name")
			if (nm != "") for (k = 1; k <= cnt; k++) if (nm == names[k]) found[k] = 1
			print treat(cur)
			cur = ""
		}
		function dump_kept(   k) {
			if (kept_done) return
			kept_done = 1
			for (k = 1; k <= cnt; k++) if (!found[k]) { print blocks[k]; kept_cnt++ }
			printf "%d\n", kept_cnt > keptf
		}
		# 收集团块; 同名先到先得(custom-groups.yaml 先载, 权威优先)
		function ldpush(   nm) {
			if (ld == "") return
			nm = field(ld, "name")
			if (nm == "") nm = "\001" (++anon)
			if (!seen[nm]) { seen[nm] = 1; cnt++; blocks[cnt] = ld; names[cnt] = nm; found[cnt] = 0 }
			ld = ""
		}
		BEGIN {
			cnt = 0; kept_cnt = 0; kept_done = 0; anon = 0
			while ((getline line < localgroups) > 0) {
				if (line ~ /^[[:space:]]*proxy-groups:[[:space:]]*$/) continue
				# 顶层键用 TOPKEY_RE 判定: 顶格的 "- name: ..." 是列表条目, 不是键
				if (line ~ topre) { ldpush(); continue }
				if (line ~ /^[[:space:]]*$/ || line ~ /^[[:space:]]*#/) {
					if (ld != "") ld = ld "\n" line
					continue
				}
				match(line, /^[[:space:]]*/)
				l2 = RLENGTH
				if (ld == "") { ld = line; ind2 = l2; continue }
				if (l2 > ind2) { ld = ld "\n" line; continue }
				ldpush(); ld = line; ind2 = l2
			}
			ldpush()
			close(localgroups)
		}
		/^proxy-groups:[[:space:]]*$/ { flush_group(); in_groups = 1; print; next }
		in_groups && $0 ~ topre { flush_group(); dump_kept(); in_groups = 0; print; next }
		in_groups {
			if ($0 ~ /^[[:space:]]*$/ || $0 ~ /^[[:space:]]*#/) {
				if (cur != "") cur = cur "\n" $0; else print
				next
			}
			match($0, /^[[:space:]]*/)
			l = RLENGTH
			if (cur == "") { cur = $0; ind = l; next }
			if (l > ind) { cur = cur "\n" $0; next }
			flush_group(); cur = $0; ind = l
			next
		}
		{ print }
		END { flush_group(); dump_kept() }
	' "$remotefile" > "$outfile"
	[ -s "$keptf" ] || echo 0 > "$keptf"
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

# ---------------------------------------------------------------------------
# 配置模版 (订阅转换)
#
# 模版不是一份可直接运行的配置, 而是「转换目标」的描述:
#   template-info:   name / desc / adapter (主选择组名, 用于 dns "#组名" 重写)
#   proxy-groups:    转换后的组; 地区组用 include-all + filter 正则自动收节点
#   rules:           转换后的规则
#   rule-providers:  可选; 模版没有时目标配置里的同名段会被移除
#
# 转换语义: 服务器 (proxies / proxy-providers) 与 dns / sniffer / tun 等其余
# 段落原样保留, 上面三段整体替换 —— 手动修改天然不丢。模版来源两处:
#   /usr/share/mihomo/templates   随包内置 (builtin/)
#   <workdir>/templates           用户自建 (user/)
# 每个 profile 可通过 uci mihomo.main.template_map 绑定一个模版
# (元素 "<profile>=<tpl-id>"), 绑定后订阅更新也走同一条转换管线。
# ---------------------------------------------------------------------------

# 从模版文件的 template-info 块里取一个字段
tpl_field() {  # $1=文件 $2=字段名 -> 值 (可能为空)
	awk -v f="$2" -v topre="$TOPKEY_RE" '
		/^template-info:[[:space:]]*$/ { inb = 1; next }
		inb && $0 ~ topre { exit }
		inb && $0 ~ "^[[:space:]]*" f ":" {
			sub("^[^:]*:[[:space:]]*", "")
			gsub(/^[[:space:]]+|[[:space:]]+$/, "")
			gsub(/^[\047\042]|[\047\042]$/, "")
			print
			exit
		}
	' "$1"
}

# 解析模版 id 为文件路径, 结果放进 $TPL。id 形如:
#   builtin:xxx.yaml / user:xxx.yaml / 裸文件名 (先 user 后 builtin, 用户覆盖优先)
resolve_tpl() {
	local id="$1" rest f=""
	[ -n "$id" ] || die "缺少模版 id"

	rest="${id#*:}"
	# 防路径穿越: 模版文件名只允许纯文件名
	case "$rest" in
		*/*|.*) die "非法模版 id: $id" ;;
	esac

	case "$id" in
		builtin:*) f="$TPL_BUILTIN/$rest" ;;
		user:*)    f="$WORKDIR/templates/$rest" ;;
		*)
			if [ -f "$WORKDIR/templates/$rest" ]; then
				f="$WORKDIR/templates/$rest"
			elif [ -f "$TPL_BUILTIN/$rest" ]; then
				f="$TPL_BUILTIN/$rest"
			fi
			;;
	esac

	[ -n "$f" ] && [ -f "$f" ] || die "找不到模版: $id"
	TPL="$f"
}

# 把 dns 段里 nameserver 条目的 "#组名" 后缀统一重写为 $2。
# 模版换了组名而 dns 还指着旧组时, 那些 nameserver 的出站代理就落空了
# (mihomo 会静默回退直连, 防环语义丢失), 所以转换必须做这一步。
# 只动 dns 块内 "- <url>#..." 形态的行, 其余行不碰。
rewrite_dns_adapter() {  # $1=文件 (原地改) $2=组名
	local t="$1.rewrite.$$"
	TMPFILES="$TMPFILES $t"
	awk -v ad="$2" -v topre="$TOPKEY_RE" '
		!indns && $0 ~ /^dns:[[:space:]]*$/ { indns = 1; print; next }
		indns && $0 ~ topre { indns = 0; print; next }
		indns && $0 ~ /^[[:space:]]*-[[:space:]]+.*https?:\/\/.*#/ {
			sub(/#.*/, "#" ad)
		}
		{ print }
	' "$1" > "$t" && mv -f "$t" "$1" || { rm -f "$t"; die "重写 dns 段组名失败"; }
}

# 删除文件里的一个顶层块; 没有该块时原样输出
remove_block() {  # $1=文件 $2=键名 -> stdout
	local r from to
	r=$(block_range "$1" "$2")
	if [ -z "$r" ]; then
		cat "$1"
	else
		from="${r%% *}"
		to="${r##* }"
		[ "$from" -gt 1 ] && head -n $((from - 1)) "$1"
		tail -n +$((to + 1)) "$1"
	fi
}

# 转换核心: 把模版的 proxy-groups / rules / rule-providers 三段装进 $1 (原地改)。
# 模版没有 rule-providers 时, 目标里的 rule-providers 一并移除 (规则已整体替换,
# 留着只会是死重)。有 adapter 时顺手重写 dns "#组名"。
# 报告: CV_NOTE(转换了什么) / CV_ADAPTER(dns 组名, 可空)
convert_profile() {
	local file="$1" tpl="$2"
	local pg ru rp out

	pg="/tmp/mihomo-conv.$$.pg"
	ru="/tmp/mihomo-conv.$$.ru"
	rp="/tmp/mihomo-conv.$$.rp"
	out="/tmp/mihomo-conv.$$.out"
	TMPFILES="$TMPFILES $pg $ru $rp $out"

	extract_block "$tpl" proxy-groups > "$pg" \
		|| die "模版 $tpl 缺少 proxy-groups 段, 无法转换"
	extract_block "$tpl" rules > "$ru" \
		|| die "模版 $tpl 缺少 rules 段, 无法转换"

	CV_ADAPTER="$(tpl_field "$tpl" adapter)"

	replace_block "$file" "$pg" proxy-groups > "$out" \
		|| die "转换失败: 无法替换 proxy-groups 段"
	mv -f "$out" "$file"

	replace_block "$file" "$ru" rules > "$out" \
		|| die "转换失败: 无法替换 rules 段"
	mv -f "$out" "$file"

	if extract_block "$tpl" rule-providers > "$rp"; then
		replace_block "$file" "$rp" rule-providers > "$out" \
			|| die "转换失败: 无法替换 rule-providers 段"
		mv -f "$out" "$file"
		CV_NOTE="proxy-groups / rules / rule-providers 已按模版重写"
	else
		remove_block "$file" rule-providers > "$out" \
			|| die "转换失败: 无法移除 rule-providers 段"
		mv -f "$out" "$file"
		CV_NOTE="proxy-groups / rules 已按模版重写, 原 rule-providers 已移除 (模版规则不使用它)"
	fi

	if [ -n "$CV_ADAPTER" ]; then
		rewrite_dns_adapter "$file" "$CV_ADAPTER"
	fi
}

# 列出全部模版: "id<TAB>描述" (builtin = 随包, user = <workdir>/templates/)
do_template_list() {
	local d f prefix desc
	for d in "$TPL_BUILTIN" "$WORKDIR/templates"; do
		[ -d "$d" ] || continue
		prefix="builtin"
		[ "$d" != "$TPL_BUILTIN" ] && prefix="user"
		for f in "$d"/*.yaml "$d"/*.yml; do
			[ -f "$f" ] || continue
			desc="$(tpl_field "$f" desc)"
			echo "$prefix:$(basename "$f")	${desc:-$(basename "$f")}"
		done
	done
}

do_template_show() {
	[ -n "$1" ] || die "template show 需要一个模版 id"
	resolve_tpl "$1"
	cat "$TPL"
}

# 把 profile 绑定到模版 (uci mihomo.main.template_map, list 元素 "<profile>=<id>")
# tplid 为 "-" 时清除绑定。走命令行 uci 而不是 rpcd 的 uci.apply, 避免触发
# config.change 事件让 mihomo 服务 reload。
do_template_bind() {
	local name="$1" tplid="$2" e

	[ -n "$name" ] || die "template bind 需要配置文件名"
	normalize_name "$name"
	name="$NAME"
	[ -n "$tplid" ] || die "template bind 需要模版 id (- 表示清除绑定)"

	# "-" 只表示清除绑定, 不走模版解析
	[ "$tplid" != "-" ] && resolve_tpl "$tplid"

	command -v uci >/dev/null 2>&1 || die "系统里没有 uci 命令, 无法保存模版绑定"
	uci -q get "mihomo.main" >/dev/null 2>&1 || die "uci 段 mihomo.main 不存在"

	uci -q delete "mihomo.main.template_map" 2>/dev/null
	for e in $TEMPLATE_MAP; do
		[ "${e%%=*}" = "$name" ] && continue
		uci -q add_list "mihomo.main.template_map=$e"
	done
	[ "$tplid" != "-" ] && uci -q add_list "mihomo.main.template_map=$name=$tplid"
	uci -q commit mihomo || die "写入 /etc/config/mihomo 失败"

	if [ "$tplid" = "-" ]; then
		echo "已清除 $name 的模版绑定 (订阅更新将保留本地 proxy-groups / rules 原样)"
	else
		echo "已把 $name 绑定到模版 $tplid (订阅更新时组与规则按该模版重写)"
	fi
	echo "RESULT: bound"
}

# 应用模版: 对现有 profile 立即执行一次转换 (不动 proxies, 订阅链接不重拉)
do_template_apply() {
	local name="$1" tplid="$2"
	local target tpl cand cand2 localg keptf chk n1 n2 stage mode before after

	[ -n "$name" ] || die "template apply 需要目标配置文件名"
	[ -n "$tplid" ] || die "template apply 需要模版 id"
	normalize_name "$name"
	name="$NAME"
	resolve_tpl "$tplid"

	target="$WORKDIR/$name"
	[ -f "$target" ] || die "目标配置不存在: $target"

	cand="/tmp/mihomo-tpl.$$.cand"
	cand2="/tmp/mihomo-tpl.$$.cand2"
	localg="/tmp/mihomo-tpl.$$.local"
	keptf="/tmp/mihomo-tpl.$$.kept"
	chk="/tmp/mihomo-tpl.$$.check"
	n1="/tmp/mihomo-tpl.$$.cmp.new"
	n2="/tmp/mihomo-tpl.$$.cmp.old"
	stage="/tmp/mihomo-tpl.$$.stage"
	TMPFILES="$TMPFILES $cand $cand2 $localg $keptf $chk $n1 $n2 $stage"

	cp -f "$target" "$cand" || die "无法读取目标配置: $target"

	echo "== 转换 =="
	echo "目标:   $target"
	echo "模版:   $tplid"
	echo
	convert_profile "$cand" "$TPL"
	echo "$CV_NOTE"
	[ -n "$CV_ADAPTER" ] && echo "dns nameserver \"#组名\" 已重写为: #$CV_ADAPTER"

	case " $CUSTOM_OFF " in
		*" $name "*)
			echo "本 profile 已关闭自定义组合并, custom.d 用户组未追加"
			;;
		*)
			if [ -s "$WORKDIR/custom.d/custom-groups.yaml" ]; then
				# localfile 传 custom-groups.yaml 自己: 应用模版的意义就是重写组,
				# 不把旧 profile 里手写的旧组复活回来; custom.d 用户组照常追加
				merge_local_groups "$WORKDIR/custom.d/custom-groups.yaml" \
					"$cand" "$cand2" "$localg" "$keptf" \
					|| die "应用模版失败: 合并自定义组时出错"
				cand="$cand2"
				echo "已追加 custom.d 里 $(cat "$keptf" 2>/dev/null) 个自定义组 (与模版组同名时以模版为准)"
			fi
			;;
	esac
	# Per-profile 覆写 (overrides/<name>.yaml): 模版与自定义组之后的最后一层,
	# 用户对单个 profile 的直接定制, 优先级最高。
	apply_override "$cand" "$name"
	if [ "$OV_APPLIED" = "1" ]; then
		echo "$OV_NOTE"
	fi
	echo

	before=$(wc -c < "$target" | tr -d ' ')
	normalize_file "$cand" > "$n1"
	normalize_file "$target" > "$n2"

	if cmp -s "$n1" "$n2"; then
		echo "模版转换结果与当前内容一致, 没有需要改动的地方。"
		echo "RESULT: unchanged"
		return 0
	fi

	echo "== 校验 (mihomo -t) =="
	check_file "$cand" > "$chk" 2>&1
	rc=$?
	cat "$chk"
	echo

	if [ "$rc" -ne 0 ]; then
		echo "-- 失败原因提示 --"
		check_hint "$chk"
		echo
		die "应用模版失败: 转换结果未通过 mihomo -t 校验 (退出码 $rc), 未修改 $target"
	fi

	echo "== 写入 =="
	cp -f "$cand" "$stage" || die "应用模版失败: 写入暂存文件失败 ($stage)"

	mode=$(stat -c '%a' "$target" 2>/dev/null)
	[ -n "$mode" ] && chmod "$mode" "$stage" 2>/dev/null

	if ! mv -f "$stage" "$target"; then
		die "应用模版失败: 替换 $target 失败"
	fi

	after=$(wc -c < "$target" | tr -d ' ')
	echo "已应用: $target ($before -> $after 字节)"
	echo

	if [ "$target" != "$CONFFILE" ]; then
		echo "当前生效的配置是 $CONFFILE, 本次改的不是它, 因此不重启服务。"
		echo "RESULT: applied"
		return 0
	fi

	if [ ! -x "$INITD" ] || ! "$INITD" running >/dev/null 2>&1; then
		echo "mihomo 服务未运行, 未执行重启 (下次启动时使用新配置)。"
		echo "RESULT: applied"
		return 0
	fi

	echo "== 重启 =="
	if "$INITD" restart; then
		echo "已重启 mihomo 服务, 模版配置已生效。"
		echo "RESULT: applied-restarted"
	else
		echo "错误: 配置已应用, 但 mihomo 服务重启失败 (详见上面的输出与系统日志)" >&2
		echo "RESULT: restart-failed"
		exit 1
	fi
}

# 应用 per-profile 覆写 (Clash Verge 的 Merge 语义)。覆写文件:
#   <workdir>/overrides/<profile>.yaml —— 存在且非空即生效, 清空即停用。
# 支持三种顶层键:
#   <key>:            该段整块替换 (如 dns: / sniffer:)
#   prepend-<key>:    条目插到该键列表最前 (rules / proxies / proxy-groups ...)
#   append-<key>:     条目追加到该键列表最后
# 其余段落不动。覆写在模版转换与自定义组追加之后执行, 是用户对单个 profile
# 的最终发言权 (优先级最高)。报告: OV_APPLIED / OV_NOTE。
apply_override() {  # $1=候选文件 (原地改) $2=profile 名
	local file="$1" name="$2"
	local ovf="$WORKDIR/overrides/$name.yaml"
	local ovkeys k key act r from to
	local tmp out

	OV_APPLIED=0
	OV_NOTE=""
	[ -s "$ovf" ] || return 0
	OV_APPLIED=1

	tmp="/tmp/mihomo-ov.$$.blk"
	out="/tmp/mihomo-ov.$$.out"
	TMPFILES="$TMPFILES $tmp $out"

	ovkeys="$(awk -v topre="$TOPKEY_RE" '
		$0 ~ topre { k = $0; sub(/:.*/, "", k); print k }
	' "$ovf")"

	[ -n "$ovkeys" ] || { OV_NOTE="覆写文件里没有可识别的顶层键, 已忽略"; return 0; }

	while IFS= read -r k; do
		[ -n "$k" ] || continue
		case "$k" in
			prepend-*) act="prepend"; key="${k#prepend-}" ;;
			append-*)  act="append";  key="${k#append-}" ;;
			*)         act="replace"; key="$k" ;;
		esac

		extract_block "$ovf" "$k" > "$tmp" || continue

		if [ "$act" = "replace" ]; then
			replace_block "$file" "$tmp" "$key" > "$out" \
				|| die "覆写失败: 无法替换 $key 段"
			mv -f "$out" "$file"
			OV_NOTE="$OV_NOTE$key=替换 "
			continue
		fi

		r=$(block_range "$file" "$key")
		if [ -z "$r" ]; then
			# 目标没有该段: 以去掉前缀的键名整段追加到文件末尾
			{
				cat "$file"
				[ -n "$(tail -c 1 "$file" 2>/dev/null)" ] && echo
				printf '%s:\n' "$key"
				awk 'NR > 1' "$tmp"
			} > "$out" && mv -f "$out" "$file" \
				|| die "覆写失败: 无法创建 $key 段"
			OV_NOTE="$OV_NOTE$key=新建 "
			continue
		fi

		from="${r%% *}"
		to="${r##* }"
		if [ "$act" = "prepend" ]; then
			{
				head -n "$from" "$file"
				awk 'NR > 1' "$tmp"
				tail -n +$((from + 1)) "$file"
			} > "$out" || die "覆写失败: 处理 $key 段时出错"
		else
			# append: 追加到该键列表真正的最后 (与 Verge Merge 语义一致;
			# 注意 rules 若以 MATCH 结尾, 追加在其后的条目不会生效)
			{
				head -n "$to" "$file"
				awk 'NR > 1' "$tmp"
				tail -n +$((to + 1)) "$file"
			} > "$out" || die "覆写失败: 处理 $key 段时出错"
		fi
		mv -f "$out" "$file"
		OV_NOTE="$OV_NOTE$key=$act "
	done <<OvKeys
$ovkeys
OvKeys

	OV_NOTE="覆写已生效: ${OV_NOTE% }"
	return 0
}

# 保存 per-profile 覆写 (LuCI 页面分块暂存后调用, 与 custom-save 同一模式)。
# 内容为空 (去注释空白后) 时删除覆写文件 = 停用覆写。
do_override_save() {
	local name="$1" src="$2" stage
	local ovdir ovf

	[ -n "$name" ] || die "override-save 需要配置文件名"
	[ -n "$src" ] || die "override-save 需要暂存文件路径"
	normalize_name "$name"
	name="$NAME"

	ovdir="$WORKDIR/overrides"
	ovf="$ovdir/$name.yaml"

	# 覆写内容只在暂存副本上校验, 原子落位后才碰工作目录
	stage="/tmp/mihomo-override.$$.yaml"
	TMPFILES="$TMPFILES $stage"
	[ -f "$src" ] || die "暂存文件不存在: $src"
	cp -f "$src" "$stage" || die "无法读取暂存文件: $src"

	# 空覆写 = 停用
	if ! grep -qE '^[A-Za-z_][A-Za-z0-9_.-]*[[:space:]]*:' "$stage"; then
		if [ -f "$ovf" ]; then
			rm -f "$ovf" 2>/dev/null || die "无法删除旧覆写文件 $ovf"
			echo "覆写内容为空, 已停用 $name 的覆写 (删除 $ovf)"
		else
			echo "覆写内容为空, $name 本来就没有覆写"
		fi
		echo "RESULT: cleared"
		return 0
	fi

	mkdir -p "$ovdir" || die "创建 $ovdir 失败"
	mv -f "$stage" "$ovf" || die "写入 $ovf 失败"
	chmod 600 "$ovf" 2>/dev/null
	echo "已写入 $ovf ($(wc -c < "$ovf" | tr -d ' ') 字节)"
	echo "RESULT: saved"
}

do_template() {
	local op="$1"
	case "$op" in
		list)  do_template_list ;;
		show)  do_template_show "$2" ;;
		apply) do_template_apply "$2" "$3" ;;
		bind)  do_template_bind "$2" "$3" ;;
		*)     die "未知 template 子命令: $op (可用: list / show / apply / bind)" ;;
	esac
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
		echo "已记录订阅链接, 之后可用「更新订阅」单独刷新服务器"
	fi

	if [ "$target" = "$CONFFILE" ]; then
		echo "该文件正是当前生效的配置, 重启 mihomo 服务后生效。"
	else
		echo "当前生效的配置是 $CONFFILE"
		echo "如需使用新配置, 请在页面上选中它并点击\"设为当前配置并重启\"。"
	fi
}

# ---------------------------------------------------------------------------
# 命令: install  (把页面拼好的暂存文件原子装进工作目录)
# ---------------------------------------------------------------------------

# 页面的「保存 / 保存并重启」不再把整份配置经 fs.write 一次发出去，而是分成
# 小块写到 /tmp 的暂存文件里 —— 一次性的大请求体会把 nginx 的 ubus 模块打崩
# (详见 htdocs/luci-static/resources/view/mihomo/upload.js)。这里负责收口：
# 复校一次 mihomo -t，然后按 do_import 的老办法原子装进工作目录。
#
# 为什么在这儿还要再校验一遍：页面已经校验过了，但暂存文件在 /tmp 里躺着，
# 期间那台机器上任何东西都能改它。装之前自己看一遍，是"候选内容通过校验前
# 绝不进工作目录"这条约定的最后一道门。
do_install() {
	local src="$1" name="$2"
	local target stage

	[ -n "$src" ] || die "缺少源文件"
	[ -n "$name" ] || die "缺少配置文件名"

	normalize_name "$name"
	name="$NAME"
	target="$WORKDIR/$name"

	[ -f "$src" ] || die "install 失败: 源文件不存在 ($src)"
	[ -s "$src" ] || die "install 失败: 源文件是空的 ($src)"
	[ -x "$PROG" ] || die "install 失败: mihomo 主程序不存在 ($PROG)"

	mkdir -p "$WORKDIR" || die "无法创建目录 $WORKDIR"

	echo "== 校验 (mihomo -t) =="
	if ! check_file "$src"; then
		echo
		die "install 失败: 配置未通过 mihomo -t 校验, 未写入 $target"
	fi
	echo

	# Rename within the same directory so the target is either the old or the
	# new file, never a half written one. 0600 matches INSTALL_CONF (配置里
	# 有订阅凭据, 不宜全局可读)。
	stage="$WORKDIR/.$name.$$"
	TMPFILES="$TMPFILES $stage"
	cp -f "$src" "$stage" || die "install 失败: 写入暂存文件失败 ($stage)"
	chmod 600 "$stage"
	if ! mv -f "$stage" "$target"; then
		die "install 失败: 替换 $target 失败"
	fi

	# 装完就把页面放在 /tmp 的那份删掉: 里面是含订阅凭据的明文, 没理由让它
	# 在临时目录里继续躺着 (页面的 rpcd 授权也覆盖这个前缀, 别人读得到)。
	rm -f "$src"

	echo "== 完成 =="
	echo "已写入: $target"

	if [ "$target" = "$CONFFILE" ]; then
		echo "该文件正是当前生效的配置, 重启 mihomo 服务后生效。"
	else
		echo "当前生效的配置是 $CONFFILE"
		echo "如需使用新配置, 请在页面上选中它并点击\"设为当前配置并重启\"。"
	fi
}

# ---------------------------------------------------------------------------
# 命令: remove  (删除一份配置文件, 连同它记录的订阅链接)
# ---------------------------------------------------------------------------

# 页面「删除选中的配置」的服务端收口。删除是破坏性操作, 这里负责三道闸:
#   1. 文件名走 normalize_name —— 与 import/install/update 同一条门, 路径穿越、
#      隐藏文件、非法字符进不来;
#   2. 当前生效的配置 (uci mihomo.main.conffile) 一律拒删 —— 删了它服务下次
#      启动就找不到配置, 页面上必须先切到别的配置再来删;
#   3. 只删 <workdir> 下确认存在的那个文件, 其它文件一概不碰。
# 删除成功后顺手把 <workdir>/sources 里该文件的订阅记录清掉: 文件都没了, 留着
# 一条指向已删文件的链接只会在「仅更新」里造成混乱。
do_remove() {
	local name="$1" target t

	[ -n "$name" ] || die "缺少配置文件名"

	normalize_name "$name"
	name="$NAME"
	target="$WORKDIR/$name"

	[ -f "$target" ] || die "删除 $name 失败: 配置文件不存在 ($target)"

	if [ "$target" = "$CONFFILE" ]; then
		die "删除 $name 失败: 它是当前生效的配置 (uci mihomo.main.conffile = $CONFFILE), 请先选中其它配置并\"设为当前配置\"后再删除"
	fi

	if ! rm -f "$target"; then
		die "删除 $name 失败: 无法删除 $target"
	fi

	# 清掉 sources 里该文件的记录; 没有记录或临时文件写失败时保持安静 ——
	# 主目标 (删文件) 已达成, 别让收尾工作把整条命令拖成失败。
	if [ -f "$SOURCES" ]; then
		t="$WORKDIR/.sources.$$"
		if awk -v n="$name" '$1 != n' "$SOURCES" > "$t" 2>/dev/null; then
			chmod 600 "$t" 2>/dev/null
			mv -f "$t" "$SOURCES" 2>/dev/null || rm -f "$t"
		else
			rm -f "$t"
		fi
	fi

	echo "== 完成 =="
	echo "已删除: $target"
	echo "已清除它记录的订阅链接 (若有)"

	# 覆写文件随 profile 一起删, 免得下次同名导入时旧覆写悄悄生效
	if [ -f "$WORKDIR/overrides/$name.yaml" ]; then
		rm -f "$WORKDIR/overrides/$name.yaml" 2>/dev/null \
			&& echo "已删除它的覆写文件 (overrides/$name.yaml)" \
			|| echo "注意: 覆写文件 overrides/$name.yaml 删除失败, 请手动清理"
	fi

	# 模版绑定也一并清掉 (走命令行 uci, 不触发 rpcd reload)
	if command -v uci >/dev/null 2>&1 && [ -n "$TEMPLATE_MAP" ]; then
		local e has=0
		for e in $TEMPLATE_MAP; do
			[ "${e%%=*}" = "$name" ] && has=1
		done
		if [ "$has" = "1" ]; then
			uci -q delete "mihomo.main.template_map" 2>/dev/null
			for e in $TEMPLATE_MAP; do
				[ "${e%%=*}" = "$name" ] && continue
				uci -q add_list "mihomo.main.template_map=$e" 2>/dev/null
			done
			uci -q commit mihomo 2>/dev/null \
				&& echo "已清除它的模版绑定" \
				|| echo "注意: 模版绑定清理失败 (uci), 请在页面上重新保存绑定"
		fi
	fi

	# 定时更新的目标若是刚删的文件, 下次 cron 一跑就会报「配置文件不存在」。
	# 只提醒, 不代改 uci: 关闭/改选是页面上的明确动作, 脚本擅自改会掩盖问题。
	if command -v uci >/dev/null 2>&1; then
		local atarget
		atarget=$(uci -q get mihomo.@autoupdate[0].target 2>/dev/null)
		if [ "$atarget" = "$name" ]; then
			echo
			echo "注意: 「定时更新」的目标正是刚删除的 $name,"
			echo "下次计划任务执行时会因找不到文件而失败。"
			echo "请在配置页面上关闭定时更新或改选其它目标配置。"
		fi
	fi
}

# ---------------------------------------------------------------------------
# 命令: update  (只替换 proxies, 其余内容原样保留; 绑定模版时组与规则按模版重写)
# ---------------------------------------------------------------------------

do_update() {
	local name="$1" url="$2" from_record=0
	local target before after cur stage
	local dl norm flog newp localg mergedg keptf m1 m2 chk rc hints reason
	local tplid n1 n2 note_p note_g note_c note_ov

	[ -n "$name" ] || die "缺少配置文件名"

	normalize_name "$name"
	name="$NAME"

	target="$WORKDIR/$name"

	[ -f "$target" ] || die "更新 $name 失败: 配置文件不存在 ($target, 更新订阅只能作用于已存在的配置)"

	if [ -z "$url" ]; then
		url="$(source_get "$name")"
		from_record=1
		if [ -z "$url" ]; then
			die "更新 $name 失败: 该配置没有记录订阅链接, 请在「更新订阅」的输入框里填写链接后重试"
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
	localg="/tmp/mihomo-update.$$.local-groups"
	mergedg="/tmp/mihomo-update.$$.merged-groups"
	keptf="/tmp/mihomo-update.$$.kept"
	m1="/tmp/mihomo-update.$$.1"
	chk="/tmp/mihomo-update.$$.check"
	n1="/tmp/mihomo-update.$$.cmp.new"
	n2="/tmp/mihomo-update.$$.cmp.old"
	TMPFILES="$TMPFILES $dl $flog $newp $localg $mergedg $keptf $m1 $chk $n1 $n2"

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

	# 新更新语义: 订阅只提供服务器 (proxies)。代理组与规则来自本地文件
	# (手动修改是权威版本) 或该 profile 绑定的模版 —— 这正是「更新时保留
	# 手动修改」的实现方式, 与 template apply 共用同一条转换管线。
	if ! extract_block "$dl" proxies > "$newp"; then
		die "更新 $name 失败: 远程配置里没有 proxies 段 (可能不是 clash/mihomo 订阅, 或上游只提供 proxy-providers; 后者请用整份导入并自行维护 providers)"
	fi

	if ! block_has_entries "$newp"; then
		die "更新 $name 失败: 远程 proxies 段为空列表, 拒绝用它覆盖本地的服务器列表"
	fi
	echo "proxies: $(wc -l < "$newp" | tr -d ' ') 行"
	echo

	# 先静默算一遍合并结果, 与磁盘上的文件比较之后再决定要不要动它。
	# 内容一致时连写盘都不做: 文件时间戳不变, 服务也就不会因为「配置文件被
	# 改过」而被 procd 的 file 检查判成需要重启, 代理不会白闪一次。
	cur="$target"
	note_p=""
	note_g=""
	note_c=""

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

	# 模版绑定: uci mihomo.main.template_map 里该 profile 的模版。
	#   绑定了模版 → proxies 来自订阅, 组/规则来自模版 (dns "#组名" 一并修正),
	#   custom.d 用户组随后追加;
	#   未绑定     → 组与规则也来自订阅 (订阅组是权威, 与历史行为一致),
	#   custom.d 用户组照旧合并。手动定制的持久载体是模版绑定与覆写,
	#   两者都不会被订阅更新冲掉。
	newg="/tmp/mihomo-update.$$.groups"
	m2="/tmp/mihomo-update.$$.2"
	TMPFILES="$TMPFILES $newg $m2"
	tplid="$(template_bound "$name" || true)"
	if [ -n "$tplid" ]; then
		resolve_tpl "$tplid"
		echo "== 转换 (模版: $tplid) =="
		convert_profile "$cur" "$TPL"
		echo "$CV_NOTE"
		[ -n "$CV_ADAPTER" ] && echo "dns nameserver \"#组名\" 已重写为: #$CV_ADAPTER"
		note_g="$CV_NOTE"

		case " $CUSTOM_OFF " in
			*" $name "*)
				note_c="本 profile 已关闭自定义组合并, 未追加"
				;;
			*)
				if [ -s "$WORKDIR/custom.d/custom-groups.yaml" ]; then
					merge_local_groups "$WORKDIR/custom.d/custom-groups.yaml" \
						"$cur" "$mergedg" "$localg" "$keptf" \
						|| die "更新 $name 失败: 合并本地自定义组时出错"
					cur="$mergedg"
					note_c="已追加 custom.d 里 $(cat "$keptf" 2>/dev/null) 个自定义组"
				else
					note_c="custom.d 里没有自定义组"
				fi
				;;
		esac
	else
		if extract_block "$dl" proxy-groups > "$newg"; then
			echo "== 提取 (远程 proxy-groups) =="
			echo "proxy-groups: $(wc -l < "$newg" | tr -d ' ') 行"
			echo
			case " $CUSTOM_OFF " in
				*" $name "*)
					note_g="本 profile 已在 LuCI 勾选关闭自定义组合并, 按订阅原始内容更新"
					;;
				*)
					merge_local_groups "$target" "$newg" "$mergedg" "$localg" "$keptf" \
						|| die "更新 $name 失败: 合并本地自定义组时出错"
					newg="$mergedg"
					note_g="已用订阅组替换, 并追加 $(cat "$keptf" 2>/dev/null) 个本地自定义组"
					;;
			esac
			replace_block "$cur" "$newg" proxy-groups > "$m2" \
				|| die "更新 $name 失败: 处理 proxy-groups 段时出错"
			cur="$m2"
		else
			note_g="远程没有 proxy-groups 段, 保持本地不变"
		fi
	fi

	# Per-profile 覆写 (overrides/<name>.yaml): 无论有没有模版都生效 —— 这是
	# 用户对单个 profile 的最后一层定制, 优先级高于模版与自定义组。
	note_ov=""
	apply_override "$cur" "$name"
	if [ "$OV_APPLIED" = "1" ]; then
		note_ov="$OV_NOTE"
		echo "$OV_NOTE"
	fi

	echo "== 对比 =="
	normalize_file "$cur" > "$n1"
	normalize_file "$target" > "$n2"

	if cmp -s "$n1" "$n2"; then
		echo "远程的 proxies 与本地一致, 没有新内容。"
		echo "未改动 $target, 也不会重启服务。"
		echo
		echo "RESULT: unchanged"

		if [ "$from_record" = 0 ]; then
			source_set "$name" "$url" \
				&& echo "已记录本次使用的订阅链接, 下次可直接点「更新订阅」无需再填写"
		fi
		return 0
	fi

	echo "有内容变化, 将做下面这些改动 (其余段落原样保留):"
	echo "proxies:       $note_p"
	echo "组与规则:      $note_g"
	[ -n "$note_c" ] && echo "自定义组:      $note_c"
	[ -n "$note_ov" ] && echo "覆写:          $note_ov"
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
	echo "组与规则: $note_g"
	[ -n "$note_c" ] && echo "自定义组: $note_c"
	[ -n "$note_ov" ] && echo "覆写: $note_ov"
	echo

	if [ "$from_record" = 0 ]; then
		if source_set "$name" "$url"; then
			echo "已记录本次使用的订阅链接, 下次可直接点「更新订阅」无需再填写"
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

# ---------------------------------------------------------------------------
# 命令: custom-save  (把 LuCI「自定义代理组」编辑区提交的暂存文件落位)
# ---------------------------------------------------------------------------

do_custom_save() {
	local stage="$1"

	load_config

	case "$stage" in
		/tmp/mihomo-config-upload.*) ;;
		*)
			die "custom-save 只接受 /tmp/mihomo-config-upload.* 暂存文件"
			;;
	esac

	[ -f "$stage" ] || die "暂存文件不存在: $stage"

	grep -qE '^[[:space:]]*proxy-groups:' "$stage" \
		|| die "内容缺少 proxy-groups: 键行: custom-groups.yaml 必须以 proxy-groups: 块为主体 (允许注释)"

	mkdir -p "$WORKDIR/custom.d" || die "创建 $WORKDIR/custom.d 失败"
	mv -f "$stage" "$WORKDIR/custom.d/custom-groups.yaml" || die "写入 $WORKDIR/custom.d/custom-groups.yaml 失败"
	chmod 600 "$WORKDIR/custom.d/custom-groups.yaml" 2>/dev/null
	echo "已写入 $WORKDIR/custom.d/custom-groups.yaml ($(wc -c < "$WORKDIR/custom.d/custom-groups.yaml" | tr -d ' ') 字节)"
	echo "RESULT: saved"
}

cmd="$1"
[ $# -gt 0 ] && shift

case "$cmd" in
	import)
		load_config
		do_import "$1" "$2" "$3"
		;;
	install)
		load_config
		do_install "$1" "$2"
		;;
	update)
		load_config
		do_update "$1" "$2"
		;;
	template)
		load_config
		do_template "$1" "$2" "$3"
		;;
	override-save)
		load_config
		do_override_save "$1" "$2"
		;;
	custom-save)
		do_custom_save "$1"
		;;
	remove)
		load_config
		do_remove "$1"
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

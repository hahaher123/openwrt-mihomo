#!/usr/bin/env bash
# 在 OpenWrt SDK 容器里编译本 feed 的包。
#
# 取代 openwrt/gh-action-sdk 这个 composite action：它给 `docker run` 的 --env
# 设了白名单，FIXUP 传不进去，而 entrypoint 会用 grep 把 "HASH uses deprecated
# hash," 当成硬失败。本包刻意用 `HASH:=skip`（geo 数据随上游 release 分支滚动、
# 上游 tag tarball 也不该钉死校验和），因此必须自己带 FIXUP=1 进容器，让
# fixup-makefile.pl 在 /feed 的工作区副本里就地补全 sha256。
#
# 需要的环境变量（与 action 同名同义）：
#   ARCH          镜像 tag 后缀，如 x86_64-25.12.6
#   FEEDNAME      feed 名，即 /feed 的挂载源名
#   PACKAGES      空格分隔的包名
#   FEED_DIR      feed 根目录（挂到 /feed）
#   ARTIFACTS_DIR 产物目录（挂到 /artifacts）
#   V / INDEX / BUILD_LOG / KEY_BUILD  透传给 entrypoint
set -e

: "${ARCH:?ARCH 未设置}"
: "${FEEDNAME:?FEEDNAME 未设置}"
: "${PACKAGES:?PACKAGES 未设置}"
FEED_DIR="${FEED_DIR:-${GITHUB_WORKSPACE:-$PWD}}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-${FEED_DIR}/artifacts}"
ENTRYPOINT="${RUNNER_TEMP:-/tmp}/sdk-entrypoint.sh"

if [ ! -x "${ENTRYPOINT}" ]; then
	echo "找不到 SDK entrypoint: ${ENTRYPOINT}" >&2
	exit 1
fi

# 容器内是 uid 1000，宿主目录先交出去，否则 entrypoint 写不了 dl/ 与 bin/。
sudo chown -R 1000:1000 "${FEED_DIR}" "${ARTIFACTS_DIR}"

# FIXUP=1：make check 发现 HASH 非 64 位 sha256 时，调 fixup-makefile.pl 就地
# 改正并视为通过（只改容器内的 /feed 副本，不回写仓库）。
docker run --rm \
	--env ARCH \
	--env BUILD_LOG \
	--env FEEDNAME \
	--env PACKAGES \
	--env V \
	--env INDEX \
	--env KEY_BUILD \
	--env FIXUP=1 \
	-v "${FEED_DIR}:/feed" \
	-v "${ARTIFACTS_DIR}:/artifacts" \
	-v "${ENTRYPOINT}:/entrypoint.sh:ro" \
	--entrypoint /entrypoint.sh \
	"ghcr.io/openwrt/sdk:${ARCH}"

# 产物归还原主，否则后面的 upload-artifact / cp 可能因属主不同失败。
sudo chown -R --reference="${FEED_DIR}/.." "${FEED_DIR}" "${ARTIFACTS_DIR}" 2>/dev/null || true

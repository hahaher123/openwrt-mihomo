#!/usr/bin/env bash
# 只保留最新 N 个 Release（默认 5），更旧的 Release 连同其资产一起删除。
#
# 为什么删 Release 而不是删 tag：
#   - Release 占仓库体积的大头（每个 3 个 APK，合计约 50 MB），tag 只有几十字节；
#   - tag 是版本锚点：build.yml 的 prepare 阶段靠「tag 是否已存在」判断该版本是否
#     已经发布过，删掉旧 tag 会让历史版本在下次改动时被误判成新版本而重编；
#   - Release 正文里的「相对上一次发布」也依赖 tag，留 tag 才能追溯。
#   所以这里只 DELETE release，不动 git tag。
#
# 环境变量：
#   GH_TOKEN          必填，需 contents:write（Actions 里用 secrets.GITHUB_TOKEN）
#   GITHUB_REPOSITORY 必填，形如 owner/repo（Actions 自动注入）
#   KEEP_RELEASES     可选，保留数量，默认 5；必须是 >=1 的整数
#   DRY_RUN           可选，设为 1 时只打印将被删除的 Release，不实际调用 DELETE
#                     （本地演练 / 排查时用；CI 不需要设置）
#
# 幂等：Release 数量不超过 KEEP 时什么都不做，可反复运行。
# 退出码：0 = 清理完成或无需清理；1 = 参数/环境错误。单个 Release 删除失败只告警，
# 不让整轮失败（下一次运行会重试）。
set -euo pipefail

KEEP="${KEEP_RELEASES:-5}"   # 未设置或为空都退回 5
REPO="${GITHUB_REPOSITORY:-}"

die() { echo "::error::$*" >&2; exit 1; }

case "$KEEP" in
  ''|*[!0-9]*) die "KEEP_RELEASES 必须是正整数（当前 '${KEEP}'）" ;;
esac
[ "$KEEP" -ge 1 ] || die "KEEP_RELEASES 必须 >= 1（当前 ${KEEP}）"
[ -n "$REPO" ] || die "缺少 GITHUB_REPOSITORY"
[ -n "${GH_TOKEN:-}" ] || die "缺少 GH_TOKEN"
command -v gh >/dev/null 2>&1 || die "未找到 gh 命令"

# GitHub 的 /releases 接口默认按 created_at 倒序返回（最新在前），分页拼接后
# 顺序依旧是全局倒序，所以不需要在本地再排序。
LIST="$(mktemp)"
# || true: EXIT trap 里的失败会改写脚本退出码 (沙箱 safe-delete / 只读 /tmp 都会踩到),
# 临时文件删不掉不该让「清理成功」变「清理失败」。
trap 'rm -f "$LIST" || true' EXIT

gh api --paginate "repos/${REPO}/releases?per_page=100" \
  --jq '.[] | "\(.id)\t\(.tag_name)"' > "$LIST" || die "拉取 Release 列表失败"

TOTAL=$(wc -l < "$LIST" | tr -d ' ')
echo "仓库: ${REPO}"
echo "当前 Release 数量: ${TOTAL}，保留最新 ${KEEP} 个"

if [ "$TOTAL" -le "$KEEP" ]; then
  echo "无需清理（数量未超过保留上限）"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
      echo "### 旧 Release 清理"
      echo ""
      echo "当前 ${TOTAL} 个 Release，保留上限 ${KEEP} 个 —— 无需清理。"
    } >> "$GITHUB_STEP_SUMMARY"
  fi
  exit 0
fi

DELETED=0
FAILED=0
DELETED_LIST=""
DRY_RUN="${DRY_RUN:-0}"

# 跳过最新 KEEP 行，其余逐条删除。
while IFS=$'\t' read -r id tag; do
  [ -n "${id:-}" ] || continue
  if [ "$DRY_RUN" = "1" ]; then
    echo "[dry-run] 将删除 Release ${tag} (id ${id})"
    DELETED=$((DELETED + 1))
    DELETED_LIST="${DELETED_LIST}- \`${tag}\`"$'\n'
    continue
  fi
  if gh api -X DELETE "repos/${REPO}/releases/${id}" >/dev/null 2>&1; then
    echo "已删除 Release ${tag} (id ${id})"
    DELETED=$((DELETED + 1))
    DELETED_LIST="${DELETED_LIST}- \`${tag}\`"$'\n'
  else
    echo "::warning::删除 Release ${tag} (id ${id}) 失败，跳过（下次运行会重试）"
    FAILED=$((FAILED + 1))
  fi
done < <(tail -n "+$((KEEP + 1))" "$LIST")

if [ "$DRY_RUN" = "1" ]; then
  echo "演练完成：将删除 ${DELETED} 个（DRY_RUN=1，未调用 DELETE）"
else
  echo "清理完成：删除 ${DELETED} 个，失败 ${FAILED} 个，剩余 $((TOTAL - DELETED)) 个"
fi

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### 旧 Release 清理"
    echo ""
    echo "保留上限 ${KEEP} 个；清理前 ${TOTAL} 个，删除 ${DELETED} 个，失败 ${FAILED} 个。"
    echo ""
    if [ -n "$DELETED_LIST" ]; then
      echo "已删除："
      echo ""
      printf '%s' "$DELETED_LIST"
    fi
  } >> "$GITHUB_STEP_SUMMARY"
fi

# 单个删除失败不算致命错误：下次发版会再清一次。
exit 0

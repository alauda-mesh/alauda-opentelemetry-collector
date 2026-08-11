#!/usr/bin/env bash
# 步骤 2：列出 OCP（os-observability/redhat-opentelemetry-collector）main 分支
# 在指定时间窗内的全部变更，并给出初判分类，供模型逐条判断 ACP 是否需要跟进。
#
# 默认时间窗: [ACP 最新 release 发布日期 - 1 个月, OCP main 最新提交日期]
# 用法: ocp-changes.sh [--since YYYY-MM-DD] [--until YYYY-MM-DD]
#
# 退出码: 0=成功   1=前置条件失败

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
repo_root
need_gh
need_cmd jq

SINCE=""
UNTIL=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --since) SINCE="${2:-}"; shift 2 ;;
    --until) UNTIL="${2:-}"; shift 2 ;;
    *) die "未知参数: $1（用法: ocp-changes.sh [--since YYYY-MM-DD] [--until YYYY-MM-DD]）" ;;
  esac
done

# ---------- 计算时间窗 ----------
REL_LINE="$(gh release list --repo "$REPO" --limit 1 --json tagName,publishedAt \
  -q '.[0] | "\(.tagName) \(.publishedAt)"' 2>/dev/null || true)"
if [[ -n "$REL_LINE" && "$REL_LINE" != "null null" ]]; then
  REL_TAG="${REL_LINE%% *}"
  REL_DATE="${REL_LINE##* }"
  REL_DATE="${REL_DATE%%T*}"
else
  REL_TAG="(无)"
  REL_DATE=""
fi

if [[ -z "$SINCE" ]]; then
  if [[ -n "$REL_DATE" ]]; then
    SINCE="$(date -u -d "$REL_DATE -1 month" +%F)"
    SINCE_NOTE="ACP 最新 release ${REL_TAG} 发布于 ${REL_DATE}，回退 1 个月"
  else
    SINCE="$(date -u -d "-6 month" +%F)"
    SINCE_NOTE="ACP 仓库没有 release，退化为最近 6 个月"
    warn "$SINCE_NOTE"
  fi
else
  SINCE_NOTE="命令行指定"
fi

OCP_HEAD_DATE="$(gh api "repos/${OCP_REPO}/commits?sha=main&per_page=1" \
  -q '.[0].commit.committer.date' | cut -dT -f1)"
[[ -n "$OCP_HEAD_DATE" ]] || die "无法获取 OCP main 的最新提交日期"
if [[ -z "$UNTIL" ]]; then
  UNTIL="$OCP_HEAD_DATE"
  UNTIL_NOTE="OCP main 最新提交日期"
else
  UNTIL_NOTE="命令行指定"
fi

OCP_MANIFEST="$WORK_DIR/ocp-manifest.yaml"
fetch "https://raw.githubusercontent.com/${OCP_REPO}/main/manifest.yaml" "$OCP_MANIFEST"
OCP_VERSION="$(manifest_version "$OCP_MANIFEST")"
ACP_VERSION="$(manifest_version manifest.yaml)"

echo "=== 时间窗 ==="
echo "  SINCE = $SINCE   （$SINCE_NOTE）"
echo "  UNTIL = $UNTIL   （$UNTIL_NOTE）"
echo
echo "=== 两侧现状 ==="
echo "  ACP 当前 collector 版本: $ACP_VERSION（本地 manifest.yaml，已含本次升级）"
echo "  OCP main 当前 collector 版本: $OCP_VERSION"
echo

# ---------- 拉取窗口内的 commit ----------
LIST="$WORK_DIR/ocp-commits.tsv"
gh api --paginate \
  "repos/${OCP_REPO}/commits?sha=main&since=${SINCE}T00:00:00Z&until=${UNTIL}T23:59:59Z&per_page=100" \
  -q '.[] | [.sha, (.commit.committer.date | split("T")[0]), (.commit.message | split("\n")[0])] | @tsv' \
  >"$LIST"

TOTAL="$(wc -l <"$LIST")"
if [[ "$TOTAL" -eq 0 ]]; then
  echo "=== 变更清单 ==="
  echo "窗口内 OCP main 没有任何提交，步骤 2 无需跟进。"
  exit 0
fi

MAX_DETAIL="${MAX_DETAIL:-80}"
if [[ "$TOTAL" -gt "$MAX_DETAIL" ]]; then
  warn "窗口内共 $TOTAL 条提交，超过 MAX_DETAIL=$MAX_DETAIL，只展开最近 $MAX_DETAIL 条的明细；"
  warn "被省略的 $((TOTAL - MAX_DETAIL)) 条较早提交请用 --since 分段再跑一次，不要当作\"没有变更\"。"
fi

echo "=== 变更清单（共 $TOTAL 条，按时间倒序）==="
echo "分类含义: MANIFEST_COMPONENT=增删了 OTel 组件 | VERSION_BUMP=仅升 collector 版本 |"
echo "          DEPS=依赖升级 | CONFIG=Dockerfile/默认配置 | RHEL_ONLY=RPM/SELinux/packit 等 ACP 不适用 |"
echo "          DOC=文档 | OTHER=其它（需人工判断）"
echo "注: OCP 把 _build/ 与 configschemas/ 的生成物也提交进仓库，这类文件在下面按\"生成物\"折叠。"
echo

# 取某个 commit 上的 manifest.yaml，缓存到 WORK_DIR；取不到返回非 0
manifest_at() {
  local sha="$1" out="$WORK_DIR/manifest-at-${1:0:8}.yaml"
  if [[ ! -s "$out" ]]; then
    curl -sSfL --retry 2 -o "$out" \
      "https://raw.githubusercontent.com/${OCP_REPO}/${sha}/manifest.yaml" 2>/dev/null || return 1
  fi
  printf '%s' "$out"
}

IDX=0
while IFS=$'\t' read -r SHA CDATE TITLE; do
  [[ -n "$SHA" ]] || continue
  IDX=$((IDX + 1))
  [[ "$IDX" -le "$MAX_DETAIL" ]] || break

  DETAIL="$WORK_DIR/ocp-commit-${SHA:0:8}.json"
  [[ -s "$DETAIL" ]] || gh api "repos/${OCP_REPO}/commits/${SHA}" >"$DETAIL"

  FILES="$(jq -r '.files[]?.filename' "$DETAIL" | sort)"
  N_FILES="$(printf '%s\n' "$FILES" | grep -c . || true)"
  # OCP 仓库把生成物也提交进来，一次提交能带 200+ 个文件；这些既不该刷屏也不该参与分类
  SIGNIFICANT="$(printf '%s\n' "$FILES" \
    | grep -vE '(^configschemas/|^_build/(build\.log|components\.go|main\.go)$|^\.gitignore$)' \
    | grep -v '^$' || true)"
  N_SIG="$(printf '%s\n' "$SIGNIFICANT" | grep -c . || true)"

  # 组件增删：直接比对本提交与父提交的 manifest.yaml 模块集合。
  # 不能用 commit API 的 .patch —— 文件数多时 GitHub 会省略 patch 字段，会漏判。
  MOD_ADD=""; MOD_DEL=""; VER_CHANGE=""
  if printf '%s\n' "$FILES" | grep -qx 'manifest.yaml'; then
    PARENT_SHA="$(jq -r '.parents[0].sha // ""' "$DETAIL")"
    CUR_M="$(manifest_at "$SHA" || true)"
    PAR_M=""
    [[ -n "$PARENT_SHA" ]] && PAR_M="$(manifest_at "$PARENT_SHA" || true)"
    if [[ -n "$CUR_M" && -n "$PAR_M" && -s "$CUR_M" && -s "$PAR_M" ]]; then
      MOD_ADD="$(comm -13 \
        <(manifest_components "$PAR_M" | awk '{ print $2 }' | sort -u) \
        <(manifest_components "$CUR_M" | awk '{ print $2 }' | sort -u) || true)"
      MOD_DEL="$(comm -23 \
        <(manifest_components "$PAR_M" | awk '{ print $2 }' | sort -u) \
        <(manifest_components "$CUR_M" | awk '{ print $2 }' | sort -u) || true)"
      PV="$(manifest_version "$PAR_M")"; CV="$(manifest_version "$CUR_M")"
      [[ "$PV" != "$CV" ]] && VER_CHANGE="$PV -> $CV"
    else
      warn "commit ${SHA:0:8} 的 manifest.yaml 取不到，组件增删未能判定，请人工看 PR"
    fi
  fi

  # 分类（只看 SIGNIFICANT）
  NON_RHEL="$(printf '%s\n' "$SIGNIFICANT" | grep -vE '(\.spec\.in$|\.te$|^\.packit\.yaml$|^\.chainsaw\.yaml$|^opentelemetry-collector\.service$|^opentelemetry-collector-with-options$|^tests/)' | grep -v '^$' || true)"
  NON_DEPS="$(printf '%s\n' "$SIGNIFICANT" | grep -vE '(^|/)(go\.mod|go\.sum)$' | grep -v '^$' || true)"
  NON_DOC="$(printf '%s\n' "$SIGNIFICANT" | grep -vE '(^README\.md$|^docs/|\.md$)' | grep -v '^$' || true)"
  if [[ -n "$MOD_ADD" || -n "$MOD_DEL" ]]; then
    CLASS="MANIFEST_COMPONENT"
  elif printf '%s\n' "$FILES" | grep -qx 'manifest.yaml'; then
    CLASS="VERSION_BUMP"
  elif [[ "$N_SIG" -gt 0 && -z "$NON_RHEL" ]]; then
    CLASS="RHEL_ONLY"
  elif [[ "$N_SIG" -gt 0 && -z "$NON_DEPS" ]]; then
    CLASS="DEPS"
  elif [[ "$N_SIG" -gt 0 && -z "$NON_DOC" ]]; then
    CLASS="DOC"
  elif printf '%s\n' "$SIGNIFICANT" | grep -qE '^(Dockerfile|configs/|00-default-receivers\.yaml)'; then
    CLASS="CONFIG"
  else
    CLASS="OTHER"
  fi

  # PR 链接（标题结尾的 (#NNN)）
  PR_REF="$(printf '%s' "$TITLE" | sed -nE 's/.*\(#([0-9]+)\)$/\1/p')"
  PR_URL="-"
  if [[ -n "$PR_REF" ]]; then PR_URL="https://github.com/${OCP_REPO}/pull/${PR_REF}"; fi

  printf '[%d] %s  %s  %s\n' "$IDX" "$CDATE" "${SHA:0:8}" "$CLASS"
  printf '    标题: %s\n' "$TITLE"
  printf '    PR:   %s\n' "$PR_URL"
  FILE_LINE="$(printf '%s\n' "$SIGNIFICANT" | head -12 | paste -sd', ' - || true)"
  if [[ "$N_SIG" -gt 12 ]]; then FILE_LINE="${FILE_LINE} ...(+$((N_SIG - 12)))"; fi
  printf '    文件: %s\n' "${FILE_LINE:-（全部为生成物）}"
  printf '    (共 %d 个文件，其中 %d 个为 _build/configschemas/.gitignore 等噪声，已折叠)\n' "$N_FILES" "$((N_FILES - N_SIG))"
  if [[ -n "$VER_CHANGE" ]]; then printf '    版本: %s\n' "$VER_CHANGE"; fi
  if [[ -n "$MOD_ADD" ]]; then printf '    组件+: %s\n' "$(printf '%s\n' "$MOD_ADD" | paste -sd', ' -)"; fi
  if [[ -n "$MOD_DEL" ]]; then printf '    组件-: %s\n' "$(printf '%s\n' "$MOD_DEL" | paste -sd', ' -)"; fi
  echo
done <"$LIST"

echo "=== 提示 ==="
echo "MANIFEST_COMPONENT 类条目会在步骤 3 的组件差异里再次出现，步骤 3 的报告需标注\"已在步骤2处理\"避免重复 review。"
echo "commit 明细 JSON 缓存在 $WORK_DIR/ 下，需要看具体 diff 时可读取，或用:"
printf '  gh api repos/%s/commits/<sha> -q %s\n' "$OCP_REPO" "'.files[] | .filename, .patch'"

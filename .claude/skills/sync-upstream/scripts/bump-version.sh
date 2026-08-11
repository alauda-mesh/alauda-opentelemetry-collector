#!/usr/bin/env bash
# 步骤 1：创建同步分支，并把 Makefile / manifest.yaml 升级到目标上游 tag。
# 只改版本号，不增删组件；不自动 commit（便于人工 review diff）。
#
# 用法: bump-version.sh <上游tag> [--dry-run]
#   例: bump-version.sh v0.158.0
#       bump-version.sh v0.158.0 --dry-run   # 只预览改写结果，不建分支不改文件
#
# 退出码: 0=BUMPED   1=前置条件失败

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
repo_root

TAG=""
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    -*) die "未知参数: $arg" ;;
    *) [[ -z "$TAG" ]] || die "只能指定一个 tag"; TAG="$arg" ;;
  esac
done

[[ -n "$TAG" ]] || die "用法: bump-version.sh <上游tag> [--dry-run]，例如: bump-version.sh v0.158.0"
[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || die "tag 格式应为 vX.Y.Z（如 v0.158.0），收到: $TAG"

need_cmd curl
need_cmd git

NEW_VERSION="${TAG#v}"
echo "目标版本: $NEW_VERSION (tag $TAG)"

# ---------- 1. 拉取上游 otelcol-contrib manifest，作为模块版本的权威来源 ----------
UP_MANIFEST="$WORK_DIR/upstream-contrib-manifest.yaml"
UP_URL="https://raw.githubusercontent.com/${OTEL_RELEASES_REPO}/${TAG}/distributions/otelcol-contrib/manifest.yaml"
if ! curl -sSfL --retry 3 --retry-delay 2 -o "$UP_MANIFEST" "$UP_URL"; then
  echo "ERROR: 无法获取上游 $TAG 的 otelcol-contrib manifest：$UP_URL" >&2
  echo "该 tag 可能不存在。最近的上游正式 tag：" >&2
  if command -v gh >/dev/null; then
    gh api "repos/${OTEL_RELEASES_REPO}/tags?per_page=100" -q '.[].name' 2>/dev/null \
      | grep -v nightly | head -8 | sed 's/^/  /' >&2 || true
  else
    echo "  (未安装 gh，请手动查看 https://github.com/${OTEL_RELEASES_REPO}/releases)" >&2
  fi
  exit 1
fi

MODMAP="$WORK_DIR/upstream-modules.txt"
awk '$1 == "-" && $2 == "gomod:" && NF == 4 { print $3, $4 }' "$UP_MANIFEST" | sort -u >"$MODMAP"
MAP_COUNT="$(wc -l <"$MODMAP")"
[[ "$MAP_COUNT" -gt 50 ]] || die "上游 manifest 解析异常，只拿到 $MAP_COUNT 个模块"
info "上游 $TAG 的 otelcol-contrib 提供 $MAP_COUNT 个模块版本参照"

# ---------- 2. 前置检查与建分支 ----------
SYNC_BRANCH="sync/${TAG}"
if [[ "$DRY_RUN" -eq 0 ]]; then
  if ! git diff --quiet || ! git diff --cached --quiet; then
    die "工作区有未提交的修改，请先处理（禁止 amend，可 commit 或 stash）"
  fi

  info "git fetch origin ..."
  git fetch origin --prune --quiet

  if git show-ref --verify --quiet "refs/heads/${SYNC_BRANCH}"; then
    die "本地已存在分支 ${SYNC_BRANCH}，请确认是否为上次未完成的同步（切过去继续，或删除后重跑）"
  fi
  if git show-ref --verify --quiet "refs/remotes/origin/${SYNC_BRANCH}"; then
    die "远端已存在分支 ${SYNC_BRANCH}，请先确认其 PR 状态，不要重复创建"
  fi

  git rev-parse --verify --quiet origin/main >/dev/null \
    || die "找不到 origin/main"
  git switch -c "$SYNC_BRANCH" origin/main --quiet
  BASE_COMMIT="$(git rev-parse --short HEAD)"
  info "已基于 origin/main ($BASE_COMMIT) 创建分支 $SYNC_BRANCH"
else
  BASE_COMMIT="$(git rev-parse --short HEAD)"
  info "[dry-run] 跳过建分支，当前 HEAD=$BASE_COMMIT"
fi

# 版本必须在切分支之后再读：本地 main 可能落后于 origin/main，提前读会拿到过期版本号，
# 进而让下面 FALLBACK 规则的 oldtrain 对不上，把该改的行判成 SKIP。
OLD_VERSION="$(makefile_ocb_version Makefile)"
[[ -n "$OLD_VERSION" ]] || die "无法从 Makefile 解析 OCB_VERSION"
MANIFEST_VERSION="$(manifest_version manifest.yaml)"
echo "当前版本: Makefile OCB_VERSION=$OLD_VERSION, manifest dist.version=$MANIFEST_VERSION"
[[ "$OLD_VERSION" == "$MANIFEST_VERSION" ]] \
  || warn "Makefile 与 manifest.yaml 的版本不一致，请在 review diff 时留意"
if [[ "$OLD_VERSION" != "$NEW_VERSION" ]]; then
  info "版本变更 $OLD_VERSION -> $NEW_VERSION"
else
  warn "当前已是目标版本，本次只会校正 manifest.yaml 中偏离的模块版本"
fi

# 下面几处校验失败时的善后提示：文件没被动，但非 dry-run 下分支已经建出来了
if [[ "$DRY_RUN" -eq 0 ]]; then
  ABORT_HINT="（仓库文件未被修改；分支 ${SYNC_BRANCH} 已创建，重跑前先 git switch main && git branch -D ${SYNC_BRANCH}）"
else
  ABORT_HINT="（dry-run，未改动任何内容）"
fi

# ---------- 3. 改写 manifest.yaml ----------
REPORT="$WORK_DIR/bump-report.tsv"
NEW_MANIFEST="$WORK_DIR/manifest.yaml.new"

awk -v mapfile="$MODMAP" \
    -v report="$REPORT" \
    -v newver="$NEW_VERSION" \
    -v oldtrain="v${OLD_VERSION}" \
    -v newtrain="v${NEW_VERSION}" '
BEGIN {
  while ((getline l < mapfile) > 0) {
    if (split(l, a, " ") >= 2) up[a[1]] = a[2]
  }
  close(mapfile)
}
# dist.version：文件中第一处两空格缩进的 version:
!distdone && /^  version:[ \t]/ {
  if ($2 != newver) printf "DIST\tdist.version\t%s\t%s\n", $2, newver > report
  print "  version: " newver
  distdone = 1
  next
}
# 组件行：  - gomod: <module> <version>
$1 == "-" && $2 == "gomod:" && NF == 4 {
  mod = $3; ver = $4
  match($0, /^[ \t]*/); indent = substr($0, 1, RLENGTH)
  if (mod in up)            { newv = up[mod]; src = "MAP";      nmap++ }
  else if (ver == oldtrain) { newv = newtrain; src = "FALLBACK"; nfb++ }
  else                      { newv = ver;      src = "SKIP";     nskip++ }
  printf "%s\t%s\t%s\t%s\n", src, mod, ver, newv > report
  print indent "- gomod: " mod " " newv
  next
}
# 其它出现 gomod: 的行形态未知，原样保留但要报出来让人看
index($0, "gomod:") > 0 {
  nbad++
  printf "UNPARSED\t%s\t-\t-\n", $0 > report
  print
  next
}
{ print }
END {
  printf "COUNTS\t%d\t%d\t%d\t%d\n", nmap+0, nfb+0, nskip+0, nbad+0 > report
}
' manifest.yaml >"$NEW_MANIFEST"

# 行数必须一致，否则说明改写逻辑出了问题。
# 用 awk NR 而不是 wc -l：manifest.yaml 末尾没有换行符，wc -l 会少算一行造成误报。
OLD_LINES="$(awk 'END { print NR }' manifest.yaml)"
NEW_LINES="$(awk 'END { print NR }' "$NEW_MANIFEST")"
[[ "$OLD_LINES" -eq "$NEW_LINES" ]] \
  || die "改写后行数变化（$OLD_LINES -> $NEW_LINES），已中止 ${ABORT_HINT}"

N_MAP=""; N_FB=""; N_SKIP=""; N_BAD=""
read -r _ N_MAP N_FB N_SKIP N_BAD <<<"$(grep '^COUNTS' "$REPORT" | tr '\t' ' ')"
[[ -n "$N_BAD" ]] || die "改写报告 $REPORT 不完整，已中止 ${ABORT_HINT}"
[[ "$N_MAP" -gt 0 ]] || die "没有任何模块版本被改写（MAP=0），manifest.yaml 结构可能已变化，已中止 ${ABORT_HINT}"

if [[ "$DRY_RUN" -eq 0 ]]; then
  cp "$NEW_MANIFEST" manifest.yaml
  sed -i -E "s|^(OCB_VERSION[[:space:]]*\?=[[:space:]]*).*|\1${NEW_VERSION}|" Makefile
  [[ "$(makefile_ocb_version Makefile)" == "$NEW_VERSION" ]] \
    || die "Makefile 的 OCB_VERSION 改写失败，请手动检查"
fi

# ---------- 4. 汇报 ----------
echo
echo "=== 模块版本改写结果 ==="
echo "MAP=$N_MAP（取自上游 $TAG 的 otelcol-contrib manifest）  FALLBACK=$N_FB（按 $OLD_VERSION 发布节奏推导）  SKIP=$N_SKIP（版本不跟随 collector 节奏，保持原样）  UNPARSED=$N_BAD"
echo
echo "--- 版本变化汇总 ---"
awk -F'\t' '$1=="MAP" || $1=="FALLBACK" { print "  " $3 " -> " $4 }' "$REPORT" \
  | sort | uniq -c | sort -rn

if [[ "$N_FB" -gt 0 ]]; then
  echo
  echo "--- FALLBACK 明细（上游 contrib 未收录该模块，按发布节奏推导，通常正确）---"
  awk -F'\t' '$1=="FALLBACK" { print "  " $2 ": " $3 " -> " $4 }' "$REPORT"
fi
if [[ "$N_SKIP" -gt 0 ]]; then
  echo
  echo "--- SKIP 明细（需人工确认是否要单独升级）---"
  awk -F'\t' '$1=="SKIP" { print "  " $2 ": " $3 " (保持不变)" }' "$REPORT"
fi
if [[ "$N_BAD" -gt 0 ]]; then
  echo
  echo "--- UNPARSED 明细（行形态未知，未做改写，必须人工处理）---"
  awk -F'\t' '$1=="UNPARSED" { print "  " $2 }' "$REPORT"
fi

echo
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "--- [dry-run] 与当前 manifest.yaml 的差异（最多 30 行）---"
  DIFF_OUT="$(diff -u manifest.yaml "$NEW_MANIFEST" | tail -n +3 || true)"
  printf '%s\n' "$DIFF_OUT" | head -30
  DIFF_LINES="$(printf '%s\n' "$DIFF_OUT" | grep -c . || true)"
  if [[ "$DIFF_LINES" -gt 30 ]]; then
    echo "  ...（共 $DIFF_LINES 行，其余省略；完整结果见 $NEW_MANIFEST）"
  fi
  echo
  echo "DRY_RUN_OK（未修改任何仓库文件；Makefile 将被改为 OCB_VERSION ?= $NEW_VERSION）"
  exit 0
fi

echo "--- git diff --stat ---"
git --no-pager diff --stat

# 残留检查：改完之后不该再出现旧版本号（除非是 SKIP 项）
LEFTOVER="$(grep -nF "${OLD_VERSION}" manifest.yaml Makefile || true)"
if [[ -n "$LEFTOVER" && "$OLD_VERSION" != "$NEW_VERSION" ]]; then
  echo
  warn "以下位置仍出现旧版本号 ${OLD_VERSION}，请确认是否为预期（SKIP 项属预期）："
  # shellcheck disable=SC2001  # 逐行加缩进，参数展开做不了
  echo "$LEFTOVER" | sed 's/^/  /'
fi

save_state TARGET_TAG "$TAG"
save_state NEW_VERSION "$NEW_VERSION"
save_state OLD_VERSION "$OLD_VERSION"
save_state SYNC_BRANCH "$SYNC_BRANCH"
save_state BASE_COMMIT "$BASE_COMMIT"

echo
echo "BUMPED"
echo "分支: $SYNC_BRANCH（基于 origin/main $BASE_COMMIT）"
echo "下一步: 后台运行 build.sh 做本地构建校验，通过后再 commit"

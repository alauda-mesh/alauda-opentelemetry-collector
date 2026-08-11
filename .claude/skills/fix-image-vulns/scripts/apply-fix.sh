#!/usr/bin/env bash
# 步骤 2b/2c：把修复落到文件上。两类修复可以在一次调用里一起做。
#
# 用法:
#   apply-fix.sh --go <X.Y.Z>                          # 修 Go 标准库漏洞
#   apply-fix.sh --replace '<模块>@v<X.Y.Z>[#CVE,CVE]' ...   # 修 Go 依赖库漏洞
#   apply-fix.sh --go 1.26.7 --replace 'golang.org/x/net@v0.46.0#CVE-2026-1234'
#
# --go       改 workflow 的 env.BUILD_BASE_IMAGE_VERSION（流水线实际生效值），
#            并把 Dockerfile 里同名 ARG 的默认值一起对齐（本地 docker build 才用得到）。
# --replace  在 manifest.yaml 的 replaces: 段里加/更新一条，ocb 会把它写进生成的 go.mod。
#            `#` 后面的 CVE 列表会写成行尾注释，方便以后知道这条 replace 为什么存在。
#            版本号要带 v 前缀（扫描给的修复候选没有 v，拼参数时补上）。
#
# 只改文件、不 commit，方便先看 diff。修复目标会记进 fix-targets.tsv，
# 由 build-verify.sh 校验构建产物里是否真的落位。
# 退出码: 0=OK  1=失败（前置条件、参数格式、目标基础镜像 tag 不存在等）

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
repo_root
load_state

[[ $# -ge 1 ]] || die "用法: apply-fix.sh [--go <X.Y.Z>] [--replace '<模块>@v<X.Y.Z>[#CVE,...]'] ..."
[[ -n "${FIX_BRANCH:-}" ]] || die "状态里没有 FIX_BRANCH，请先执行 create-fix-branch.sh"
CUR="$(git branch --show-current || true)"
[[ "$CUR" == "$FIX_BRANCH" ]] || die "当前分支是 $CUR，应在修复分支 $FIX_BRANCH 上执行"

GO_VER=""
REPLACES=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --go)      [[ $# -ge 2 ]] || die "--go 后面要跟版本号，如 --go 1.26.7"
               GO_VER="$2"; shift 2 ;;
    --replace) [[ $# -ge 2 ]] || die "--replace 后面要跟 <模块>@v<版本>[#CVE,...]"
               REPLACES+=("$2"); shift 2 ;;
    *)         die "无法识别的参数: $1" ;;
  esac
done
[[ -n "$GO_VER" || ${#REPLACES[@]} -gt 0 ]] || die "没有指定任何修复内容（--go / --replace 至少给一个）"

touch "$FIX_TARGETS"
# record_target KIND NAME VERSION —— 幂等（同 KIND+NAME 只保留最新一条）
record_target() {
  awk -F'\t' -v k="$1" -v n="$2" '!($1 == k && $2 == n)' "$FIX_TARGETS" >"$FIX_TARGETS.tmp" || true
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$FIX_TARGETS.tmp"
  mv "$FIX_TARGETS.tmp" "$FIX_TARGETS"
}

# ---------- 修 Go 标准库：升构建基础镜像的 Go 版本 ----------
if [[ -n "$GO_VER" ]]; then
  [[ "$GO_VER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "--go 的版本格式应为 X.Y.Z（不带 go 前缀），收到: $GO_VER"

  OLD_GO="$(workflow_go_version)"
  [[ -n "$OLD_GO" ]] || die "无法从 $WORKFLOW_FILE 解析出 BUILD_BASE_IMAGE_VERSION，请人工确认文件结构"
  ver_ge "$GO_VER" "$OLD_GO" || die "目标版本 $GO_VER 低于当前的 $OLD_GO，拒绝降级。确认修复候选是否填错。"

  # 生成代码要求的最低 Go 版本，基础镜像不能低于它
  if [[ -f _build/go.mod ]]; then
    REQ="$(awk '/^go[[:space:]]+[0-9]/ { print $2; exit }' _build/go.mod)"
    [[ -n "$REQ" ]] && ! ver_ge "$GO_VER" "$REQ" \
      && die "目标 Go $GO_VER 低于 _build/go.mod 要求的 $REQ，构建必然失败"
  fi

  # 目标 tag 在构建基础镜像仓库里必须存在，否则流水线跑到拉镜像才失败，白等一轮
  TAG_STATE="$(check_base_image_tag "$GO_VER")"
  case "$TAG_STATE" in
    EXISTS)  info "构建基础镜像 golang:$GO_VER 存在" ;;
    MISSING) die "构建基础镜像 ${BASE_IMAGE_PATH}:${GO_VER} 在 $BASE_IMAGE_REGISTRY 不存在（404），换一个确实发布了的补丁版本" ;;
    *)       warn "无法确认 ${BASE_IMAGE_PATH}:${GO_VER} 是否存在（$TAG_STATE），流水线拉不到基础镜像时优先怀疑这里" ;;
  esac

  N="$(grep -cE '^[[:space:]]*BUILD_BASE_IMAGE_VERSION:' "$WORKFLOW_FILE" || true)"
  [[ "$N" -eq 1 ]] || die "$WORKFLOW_FILE 里 BUILD_BASE_IMAGE_VERSION 有 $N 处（预期 1 处），请人工用 Edit 修改"
  sed -i -E "s|^([[:space:]]*BUILD_BASE_IMAGE_VERSION:[[:space:]]*).*$|\1$GO_VER|" "$WORKFLOW_FILE"
  [[ "$(workflow_go_version)" == "$GO_VER" ]] || die "$WORKFLOW_FILE 替换未生效，请人工用 Edit 修改"
  echo "OK: $WORKFLOW_FILE  BUILD_BASE_IMAGE_VERSION: $OLD_GO → $GO_VER  <- 流水线实际生效值"

  # Dockerfile 的 ARG 默认值会被流水线的 build-arg 覆盖，但保持一致才不会误导本地构建
  if grep -qE '^ARG BUILD_BASE_IMAGE_VERSION=' Dockerfile; then
    OLD_DF="$(awk -F'=' '/^ARG BUILD_BASE_IMAGE_VERSION=/ { print $2; exit }' Dockerfile)"
    sed -i -E "s|^(ARG BUILD_BASE_IMAGE_VERSION=).*$|\1$GO_VER|" Dockerfile
    echo "OK: Dockerfile     ARG 默认值: $OLD_DF → $GO_VER  （被流水线覆盖，仅本地 docker build 用）"
  fi

  record_target stdlib go "$GO_VER"

  if [[ "$(cut -d. -f1-2 <<<"$OLD_GO")" != "$(cut -d. -f1-2 <<<"$GO_VER")" ]]; then
    echo "GO_MINOR_CHANGED: $OLD_GO → $GO_VER 跨了 Go 次版本，最终报告里要着重说明这次大版本变更及原因"
  fi
fi

# ---------- 修 Go 依赖库：manifest.yaml 加 replaces ----------
for SPEC in "${REPLACES[@]}"; do
  CVES=""
  [[ "$SPEC" == *"#"* ]] && { CVES="${SPEC#*#}"; SPEC="${SPEC%%#*}"; }
  [[ "$SPEC" == *"@"* ]] || die "--replace 参数格式应为 <模块>@v<版本>[#CVE,...]，收到: $SPEC"
  MOD="${SPEC%@*}"; VER="${SPEC##*@}"
  [[ "$VER" =~ ^v ]] || die "版本号要带 v 前缀（收到 $VER）。扫描给的修复候选没有 v，拼参数时补上。"

  # replace 是精确钉版本，比当前解析到的版本低就会造成降级——这是最容易踩的坑
  if [[ -f _build/go.mod ]]; then
    NOW="$(awk -v m="$MOD" '$1 == m { print $2; exit }' _build/go.mod)"
    if [[ -n "$NOW" ]] && ! ver_ge "$VER" "$NOW"; then
      warn "$MOD 当前已解析到 $NOW，replace 到 $VER 会把它降级（replace 是精确钉版本）。"
      warn "请改用不低于 $NOW 的版本，否则可能引入新问题。"
    fi
  fi

  ENTRY="  - ${MOD} => ${MOD} ${VER}"
  [[ -n "$CVES" ]] && ENTRY="${ENTRY} # ${CVES}"

  if grep -qF "  - ${MOD} =>" manifest.yaml; then
    awk -v mod="$MOD" -v new="$ENTRY" \
      '{ if (index($0, "  - " mod " =>") == 1) print new; else print }' \
      manifest.yaml >manifest.yaml.tmp && mv manifest.yaml.tmp manifest.yaml
    echo "OK: manifest.yaml 更新 replaces 条目 → ${ENTRY#  - }"
  elif grep -qE '^replaces:[[:space:]]*$' manifest.yaml; then
    # 追加到 replaces 段末尾（段一直延续到下一个顶层 key 或文件结束）
    awk -v new="$ENTRY" '
      /^replaces:[[:space:]]*$/ { print; inblk = 1; next }
      inblk && /^[^[:space:]#]/ { print new; ins = 1; inblk = 0 }
      { print }
      END { if (inblk && !ins) print new }
    ' manifest.yaml >manifest.yaml.tmp && mv manifest.yaml.tmp manifest.yaml
    echo "OK: manifest.yaml 新增 replaces 条目 → ${ENTRY#  - }"
  else
    { echo; echo "# 安全修复：把有漏洞的依赖钉到修复版本（由 /fix-image-vulns 维护）"
      echo "# 上游发布新版本自然带上这些版本之后，可以清理掉对应条目。"
      echo "replaces:"; echo "$ENTRY"; } >>manifest.yaml
    echo "OK: manifest.yaml 新建 replaces 段并加入 → ${ENTRY#  - }"
  fi

  record_target gomod "$MOD" "$VER"
done

echo
echo "--- 本次改动 ---"
git --no-pager diff --stat
echo
echo "修复目标（build-verify.sh 会核对这些目标在构建产物里是否真的落位）:"
sed 's/^/  /' "$FIX_TARGETS"
echo "下一步: 后台执行 build-verify.sh 做本地构建与落位校验"

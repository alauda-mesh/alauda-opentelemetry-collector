#!/usr/bin/env bash
# 步骤 2d：本地构建验证 + 修复落位校验。
#
# 用法: build-verify.sh
# 做三件事：
#   1. make build 重新生成并编译整个发行版（ocb 会按 manifest.yaml 重算 go.mod）；
#   2. 用 `go version -m` 读构建产物里嵌的依赖清单——这正是 Trivy 扫镜像时读的东西，
#      逐条核对 fix-targets.tsv 里的修复目标是否真的落到了产物上。
#      不做这一步，一个没生效的 replace 要等 30 分钟流水线 + 一轮扫描才暴露；
#   3. 校验流水线的 BUILD_BASE_IMAGE_VERSION 不低于生成代码要求的 Go 版本。
#
# 编译整个发行版通常几分钟到十几分钟，请用后台方式运行（Bash 的 run_in_background: true）。
# 退出码: 0=BUILD_OK（构建通过且修复目标全部落位）
#         2=BUILD_FAILED
#         3=TARGET_UNMET（构建通过，但有修复目标没落位，直接提 PR 也修不掉漏洞）
#         1=前置条件失败

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
repo_root
load_state
need_cmd go
need_cmd make

BUILD_LOG="$WORK_DIR/build.log"
OCB_VERSION="$(awk -F'=' '/^OCB_VERSION[[:space:]]*\?=/ { gsub(/[[:space:]]/, "", $2); print $2; exit }' Makefile)"

# Makefile 的 ocb 目标里，PATH 上能找到 ocb 时会直接用它并忽略 OCB_VERSION
if command -v ocb >/dev/null; then
  warn "PATH 上存在全局 ocb（$(command -v ocb)），Makefile 会优先用它并忽略 OCB_VERSION=${OCB_VERSION}"
fi
# bin/ocb 已存在时 Makefile 会跳过安装，于是沿用旧版本；主动删掉强制按 OCB_VERSION 重装
rm -f bin/ocb
# Makefile 里写死了 `mv $(go env GOPATH)/bin/builder`，而 go install 实际装到 GOBIN。
# mise/asdf 会把 GOBIN 指到别处导致那个 mv 找不到文件，这里对齐到 Makefile 的假设。
GOBIN_ALIGNED="$(go env GOPATH)/bin"; mkdir -p "$GOBIN_ALIGNED"; export GOBIN="$GOBIN_ALIGNED"

echo "开始本地构建（OCB_VERSION=${OCB_VERSION}，日志: $BUILD_LOG）..."
# Makefile 里 ocb 的输出走了 tee，make 的退出码是 tee 的，不能只看退出码；
# 先删产物，用"产物是否重新生成"作为硬判据。
rm -f _build/otelcol
set +e
make build >"$BUILD_LOG" 2>&1
MAKE_RC=$?
set -e

if [[ "$MAKE_RC" -ne 0 || ! -x _build/otelcol ]]; then
  echo "BUILD_FAILED (make 退出码=$MAKE_RC, 产物存在=$([[ -x _build/otelcol ]] && echo yes || echo no))"
  echo
  echo "--- 错误相关行 ---"
  grep -inE "error|cannot find|no required module|undefined:|missing go.sum|failed|panic:|ambiguous" "$BUILD_LOG" \
    | tail -30 || echo "(未匹配到明显错误行)"
  echo "--- 日志末尾 ---"
  tail -25 "$BUILD_LOG"
  echo
  echo "完整日志: $BUILD_LOG"
  exit 2
fi
echo "BUILD_SUCCESS"

# ---------- 修复落位校验 ----------
# go version -m 读的是二进制里嵌的构建信息，Trivy 扫镜像看的也是它，所以这是最贴近扫描结果的判据。
# 输出形如:   dep  golang.org/x/net  v0.44.0  h1:...
#             =>   golang.org/x/net  v0.46.0  h1:...   （有 replace 时追加一行，以它为准）
EFFECTIVE="$WORK_DIR/effective-modules.tsv"
go version -m ./_build/otelcol 2>/dev/null | awk '
  $1 == "dep" { mod = $2; ver[mod] = $3 }
  $1 == "=>"  { if (mod != "") ver[mod] = $3 }
  END { for (m in ver) printf "%s\t%s\n", m, ver[m] }
' | sort >"$EFFECTIVE"

UNMET=0
echo
echo "=== 修复落位校验 ==="
if [[ ! -s "${FIX_TARGETS:-}" ]]; then
  echo "  （fix-targets.tsv 为空：本次没有通过 apply-fix.sh 记录的修复目标，跳过）"
else
  while IFS=$'\t' read -r KIND NAME WANT; do
    [[ -n "$KIND" ]] || continue
    if [[ "$KIND" == "stdlib" ]]; then
      # 产物里的 Go 版本是本机工具链的，不代表流水线；流水线用的是 BUILD_BASE_IMAGE_VERSION
      WF_GO="$(workflow_go_version)"
      if [[ -n "$WF_GO" ]] && ver_ge "$WF_GO" "$WANT"; then
        echo "  [OK]     stdlib: workflow BUILD_BASE_IMAGE_VERSION=$WF_GO >= 目标 $WANT"
      else
        echo "  [UNMET]  stdlib: workflow BUILD_BASE_IMAGE_VERSION=${WF_GO:-未知} < 目标 $WANT"
        UNMET=$((UNMET + 1))
      fi
      echo "           （本地产物的 go$(go version -m ./_build/otelcol 2>/dev/null | awk 'NR==1{print $2}' | sed 's/^go//') 是本机工具链版本，与流水线无关，不用于判定）"
    else
      GOT="$(awk -F'\t' -v m="$NAME" '$1 == m { print $2; exit }' "$EFFECTIVE")"
      if [[ -z "$GOT" ]]; then
        echo "  [UNMET]  $NAME: 产物里找不到该模块（replace 可能拼错模块路径，或它已不在依赖图中）"
        UNMET=$((UNMET + 1))
      elif ver_ge "$GOT" "$WANT"; then
        echo "  [OK]     $NAME: 产物实际版本 $GOT >= 目标 $WANT"
      else
        echo "  [UNMET]  $NAME: 产物实际版本 $GOT < 目标 $WANT"
        UNMET=$((UNMET + 1))
      fi
    fi
  done <"$FIX_TARGETS"
fi

# ---------- Go 版本一致性 ----------
# 新依赖可能抬高 go 指令，本地能编过但流水线的构建基础镜像过旧时 CI 必然失败
echo
echo "=== Go 版本一致性 ==="
GO_REQUIRED="$(awk '/^go[[:space:]]+[0-9]/ { print $2; exit }' _build/go.mod 2>/dev/null || true)"
WF_GO="$(workflow_go_version)"
echo "  生成代码要求 (_build/go.mod): ${GO_REQUIRED:-未知}"
echo "  流水线构建镜像 ($WORKFLOW_FILE): ${WF_GO:-未知}   <- 实际生效值"
if [[ -n "$GO_REQUIRED" && -n "$WF_GO" ]]; then
  if ver_ge "$WF_GO" "$GO_REQUIRED"; then
    echo "  结论: OK"
  else
    warn "BUILD_BASE_IMAGE_VERSION ($WF_GO) 低于生成代码要求的 Go ($GO_REQUIRED)，CI 构建会失败。"
    warn "用 apply-fix.sh --go <不低于 $GO_REQUIRED 的版本> 提上去。"
    UNMET=$((UNMET + 1))
  fi
fi

echo
if [[ "$UNMET" -gt 0 ]]; then
  echo "RESULT: TARGET_UNMET（${UNMET} 项未落位）"
  echo "此时提 PR 也修不掉对应漏洞。先分析原因（replace 版本写低了 / 模块路径写错 /"
  echo "该 CVE 实际来自另一个模块），改完重跑本脚本。"
  exit 3
fi
echo "RESULT: BUILD_OK"
echo "下一步: git add -A && git commit（禁止 amend），然后执行 create-pr.sh"

#!/usr/bin/env bash
# 步骤 1/2/3：本地构建校验（make build）+ 构建期 Go 版本一致性检查。
# 编译整个发行版通常需要几分钟到十几分钟，请用后台方式运行。
#
# 用法: build.sh
# 退出码: 0=BUILD_SUCCESS   2=BUILD_FAILED   1=前置条件失败

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
repo_root

need_cmd go
need_cmd make

BUILD_LOG="$WORK_DIR/build.log"
COMPONENTS_OUT="$WORK_DIR/components.yaml"

OCB_VERSION="$(makefile_ocb_version Makefile)"

# Makefile 的 ocb 目标里，"命令行上能找到 ocb" 时会直接用它并完全忽略 OCB_VERSION。
if command -v ocb >/dev/null; then
  warn "PATH 上存在全局 ocb（$(command -v ocb)），Makefile 会优先使用它并忽略 OCB_VERSION=${OCB_VERSION}。"
  warn "本地构建校验的就不是目标版本了，建议把它从 PATH 移开后重跑。"
fi

# Makefile 的 ocb 目标在 bin/ocb 已存在时会跳过安装（[ ! -x ... ] || exit 0），
# 于是版本升级后会沿用上一版本的 ocb。主动删掉，强制按当前 OCB_VERSION 重新安装。
rm -f bin/ocb

# Makefile 里写死了 `mv $(go env GOPATH)/bin/builder`，但 go install 实际会装到 GOBIN。
# mise/asdf 这类工具会把 GOBIN 指到自己的目录，导致那个 mv 找不到文件。
# 这里把 GOBIN 对齐到 Makefile 的假设，只影响本次子进程，不动用户环境。
GOBIN_ALIGNED="$(go env GOPATH)/bin"
mkdir -p "$GOBIN_ALIGNED"
export GOBIN="$GOBIN_ALIGNED"

echo "开始本地构建（OCB_VERSION=${OCB_VERSION}，日志: $BUILD_LOG）..."
# Makefile 里 ocb 的输出走了 tee，make 的退出码是 tee 的，不能只看退出码；
# 先删掉旧产物，用"产物是否重新生成"作为构建成功的硬判据。
rm -f _build/otelcol
set +e
make build >"$BUILD_LOG" 2>&1
MAKE_RC=$?
set -e

if [[ "$MAKE_RC" -ne 0 || ! -x _build/otelcol ]]; then
  echo "BUILD_FAILED (make 退出码=$MAKE_RC, 产物存在=$([[ -x _build/otelcol ]] && echo yes || echo no))"
  echo
  echo "--- 错误相关行 ---"
  grep -inE "error|cannot find|no required module|undefined:|missing go.sum|failed|panic:" "$BUILD_LOG" \
    | tail -30 || echo "(未匹配到明显错误行)"
  echo "--- 日志末尾 ---"
  tail -25 "$BUILD_LOG"
  echo
  echo "完整日志: $BUILD_LOG"
  exit 2
fi

echo "BUILD_SUCCESS"
echo

# ---------- Go 版本一致性检查 ----------
# 新版本 collector 抬高 go 指令时，本地能编过但流水线用的构建基础镜像可能过旧，
# 这类问题只会在 CI 暴露，所以在这里提前拦一道。
GO_REQUIRED="$(awk '/^go[[:space:]]+[0-9]/ { print $2; exit }' _build/go.mod 2>/dev/null || true)"
WF_FILE=".github/workflows/alauda-build-otelcol.yaml"
WF_GO="$(awk -F':' '/^[[:space:]]+BUILD_BASE_IMAGE_VERSION:/ { gsub(/[[:space:]"]/, "", $2); print $2; exit }' "$WF_FILE" 2>/dev/null || true)"
DF_GO="$(awk -F'=' '/^ARG BUILD_BASE_IMAGE_VERSION=/ { print $2; exit }' Dockerfile 2>/dev/null || true)"

echo "=== Go 版本检查 ==="
echo "  生成代码要求 (_build/go.mod): ${GO_REQUIRED:-未知}"
echo "  流水线构建镜像 ($WF_FILE): ${WF_GO:-未知}   <- 实际生效值"
echo "  Dockerfile ARG 默认值: ${DF_GO:-未知}   （被流水线覆盖，仅供本地 docker build 使用）"
if [[ -n "$GO_REQUIRED" && -n "$WF_GO" ]]; then
  if [[ "$(printf '%s\n%s\n' "$GO_REQUIRED" "$WF_GO" | sort -V | head -1)" != "$GO_REQUIRED" ]]; then
    warn "流水线的 BUILD_BASE_IMAGE_VERSION ($WF_GO) 低于生成代码要求的 Go ($GO_REQUIRED)，CI 构建会失败。"
    warn "需要把 $WF_FILE 的 BUILD_BASE_IMAGE_VERSION 提升到 >= $GO_REQUIRED（Dockerfile 的 ARG 默认值建议一并跟上）。"
  else
    echo "  结论: OK"
  fi
else
  warn "未能解析出全部 Go 版本信息，请人工确认"
fi

# ---------- 组件完整性检查 ----------
# 权威判据是 ocb 生成的 _build/*.go：manifest 里每个模块都必须出现在生成代码里
# （组件在 components.go，providers 在 main.go）。少了就说明该组件没被编译进去。
echo
echo "=== 组件完整性检查 ==="
N_DECLARED=0
MISSING_MODS=""
while read -r sec mod _; do
  [[ -n "$mod" ]] || continue
  N_DECLARED=$((N_DECLARED + 1))
  grep -qFh -- "$mod" _build/*.go 2>/dev/null || MISSING_MODS="${MISSING_MODS}  [${sec}] ${mod}"$'\n'
done < <(manifest_components manifest.yaml)

echo "  manifest.yaml 声明模块数: $N_DECLARED"
if [[ -n "$MISSING_MODS" ]]; then
  warn "以下模块没有出现在 ocb 生成的代码里，说明没被编译进产物，必须查清："
  printf '%s' "$MISSING_MODS"
else
  echo "  结论: OK（全部模块均已进入生成代码）"
fi

# ---------- 组件清单（仅供参考）----------
echo
echo "=== otelcol components 输出（仅供参考）==="
if ./_build/otelcol components >"$COMPONENTS_OUT" 2>/dev/null; then
  awk '
    /^[a-z]+:/ { sec = substr($0, 1, index($0, ":") - 1); next }
    sec == "buildinfo" && $1 == "version:" { ver = $2 }
    $1 == "-" && ($2 == "name:" || $2 == "scheme:") { cnt[sec]++ }
    END {
      printf "  二进制内 buildinfo.version: %s\n", (ver == "" ? "未知" : ver)
      for (s in cnt) printf "  %-12s %d\n", s, cnt[s]
    }
  ' "$COMPONENTS_OUT" | sort
  echo "  注意: 这里的数量在不同版本上并不稳定，对不上不代表组件缺失"
  echo "  （0.147.0 会漏列 otlp/otlphttp exporter 与 k8sattributes processor，但它们确实编译进去了；"
  echo "   0.158.0 实测已修复、与 manifest 完全吻合。对得上同样不构成结论）。"
  echo "  判断组件有没有丢，以上面的\"组件完整性检查\"为准。"
  echo "  完整清单: $COMPONENTS_OUT"
else
  warn "执行 ./_build/otelcol components 失败，请人工确认产物是否可用"
fi

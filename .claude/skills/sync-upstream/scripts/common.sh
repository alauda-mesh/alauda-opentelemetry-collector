#!/usr/bin/env bash
# 公共函数与常量，供各步骤脚本 source 使用。

set -euo pipefail

# 本仓库
REPO="${REPO:-alauda-mesh/alauda-opentelemetry-collector}"
# 上游 OpenTelemetry Collector 发行版仓库：OCB 版本与各组件模块版本的权威来源
OTEL_RELEASES_REPO="${OTEL_RELEASES_REPO:-open-telemetry/opentelemetry-collector-releases}"
# Red Hat build of OpenTelemetry（下文简称 OCP）：本仓库 manifest.yaml 的参照对象
OCP_REPO="${OCP_REPO:-os-observability/redhat-opentelemetry-collector}"
# 需要监控的流水线（.github/workflows/alauda-build-otelcol.yaml 的 name）
WORKFLOW_NAME="${WORKFLOW_NAME:-Alauda Build OpenTelemetry Collector}"

die() { echo "ERROR: $*" >&2; exit 1; }
warn() { echo "WARN: $*"; }
info() { echo "INFO: $*"; }

# 定位仓库根目录并 cd 过去，同时导出 ROOT / GIT_DIR_ABS / STATE_FILE / WORK_DIR
repo_root() {
  local root
  root=$(git rev-parse --show-toplevel 2>/dev/null) || die "当前目录不在 git 仓库内"
  [[ -f "$root/manifest.yaml" && -f "$root/Makefile" ]] \
    || die "当前仓库不是 alauda-opentelemetry-collector（缺少 manifest.yaml 或 Makefile）"
  cd "$root"
  # shellcheck disable=SC2034  # 供各步骤脚本按需引用
  ROOT="$root"
  GIT_DIR_ABS="$(git rev-parse --absolute-git-dir)"
  # 中间产物统一放在 .git/ 下：天然不入库，也不会被 make build 清理 _build 波及
  WORK_DIR="$GIT_DIR_ABS/otel-sync"
  mkdir -p "$WORK_DIR"
  STATE_FILE="$WORK_DIR/state.env"
}

# save_state KEY VALUE —— 幂等写入（先删同名 key）
save_state() {
  local key="$1" val="$2"
  touch "$STATE_FILE"
  sed -i "/^${key}=/d" "$STATE_FILE"
  printf '%s=%s\n' "$key" "$val" >>"$STATE_FILE"
}

load_state() {
  [[ -f "$STATE_FILE" ]] || die "未找到状态文件 $STATE_FILE，请先执行 bump-version.sh"
  # shellcheck disable=SC1090
  source "$STATE_FILE"
  [[ -n "${TARGET_TAG:-}" ]] || die "状态文件内容不完整，请重新执行 bump-version.sh"
}

need_cmd() { command -v "$1" >/dev/null || die "未安装 $1"; }

need_gh() {
  need_cmd gh
  gh auth status >/dev/null 2>&1 || die "gh 未认证，请提示用户执行: ! gh auth login"
}

# 读取 manifest.yaml 的 dist.version（文件中第一处两空格缩进的 version:）
manifest_version() {
  awk '/^  version:[[:space:]]/ { print $2; exit }' "$1"
}

# 读取 Makefile 的 OCB_VERSION
makefile_ocb_version() {
  awk -F'=' '/^OCB_VERSION[[:space:]]*\?=/ { gsub(/[[:space:]]/, "", $2); print $2; exit }' "$1"
}

# 从 manifest.yaml 抽出 "<section> <module> <version>" 三元组，供组件对比使用。
# 只认 "  - gomod: <module> <version>" 这一种行形态；顶层 key（receivers: 等）作为 section。
manifest_components() {
  awk '
    /^[a-z_]+:[[:space:]]*$/ { section = substr($0, 1, index($0, ":") - 1); next }
    $1 == "-" && $2 == "gomod:" && NF == 4 { print section, $3, $4 }
  ' "$1"
}

# 下载 URL 到文件，失败即退出（curl 的 -f 让 404 也算失败）
fetch() {
  local url="$1" out="$2"
  curl -sSfL --retry 3 --retry-delay 2 -o "$out" "$url" \
    || die "下载失败: $url"
}

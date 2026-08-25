#!/usr/bin/env bash
# 公共函数与常量，供各步骤脚本 source 使用。
#
# 中间产物统一放在 .git/otel-vulnfix/ 下：天然不入库，也不会被 make build 清理 _build 波及。
#   state.env              步骤间传递的键值状态（ROUND / BASE_BRANCH / FIX_BRANCH / PR_NUMBER）
#   images-round<N>.txt    第 N 轮待扫描镜像，一行一个
#   scans/round<N>/        扫描原始 JSON 与分类后的 vulns.tsv
#   fix-targets.tsv        apply-fix.sh 记录的修复目标，build-verify.sh 用它校验是否真的落位

set -euo pipefail

REPO="${REPO:-alauda-mesh/alauda-opentelemetry-collector}"
WORKFLOW_NAME="${WORKFLOW_NAME:-Alauda Build OpenTelemetry Collector}"
WORKFLOW_FILE=".github/workflows/alauda-build-otelcol.yaml"
# shellcheck disable=SC2034  # 下面这些常量/变量由各步骤脚本 source 后引用
IMAGE_REPO="build-harbor.alauda.cn/asm/opentelemetry-collector"

# 内网镜像漏洞扫描服务：主地址优先，备用地址的服务容易故障（scan-image.sh 会探测后选用）
SCAN_API_PRIMARY="${SCAN_API_PRIMARY:-http://192.168.141.42:8888}"
SCAN_API_BACKUP="${SCAN_API_BACKUP:-http://192.168.25.100:8888}"

# 对照镜像：一个「必定有漏洞」的公共镜像，用于在扫描结果为 0 条时反证扫描链路是通的。
# 扫描 API 的 os/lang 数组里只装漏洞、不装包清单，所以「0 条」自己证明不了自己，
# 必须靠对照组区分「真干净」和「服务/DB 坏了、对什么都返回空」。
# 实测 2026-08: golang:1.21 → os 6364 条 + lang 969 条。
CONTROL_IMAGE="${CONTROL_IMAGE:-docker-mirrors.alauda.cn/library/golang:1.21}"

# 构建基础镜像（golang）所在的 registry，用于校验目标 Go 版本的 tag 是否真的存在
BASE_IMAGE_REGISTRY="${BASE_IMAGE_REGISTRY:-https://docker-mirrors.alauda.cn}"
BASE_IMAGE_PATH="${BASE_IMAGE_PATH:-library/golang}"

die()  { echo "ERROR: $*" >&2; exit 1; }
warn() { echo "WARN: $*"; }
info() { echo "INFO: $*"; }

# 定位仓库根目录并 cd 过去，导出 ROOT / WORK_DIR / STATE_FILE
repo_root() {
  local root
  root=$(git rev-parse --show-toplevel 2>/dev/null) || die "当前目录不在 git 仓库内"
  [[ -f "$root/manifest.yaml" && -f "$root/$WORKFLOW_FILE" ]] \
    || die "当前仓库不是 alauda-opentelemetry-collector（缺少 manifest.yaml 或 $WORKFLOW_FILE）"
  cd "$root"
  # shellcheck disable=SC2034  # 供各步骤脚本按需引用
  ROOT="$root"
  WORK_DIR="$(git rev-parse --absolute-git-dir)/otel-vulnfix"
  mkdir -p "$WORK_DIR"
  STATE_FILE="$WORK_DIR/state.env"
  # shellcheck disable=SC2034  # apply-fix.sh / build-verify.sh 引用
  FIX_TARGETS="$WORK_DIR/fix-targets.tsv"
}

# save_state KEY VALUE —— 幂等写入（先删同名 key）
save_state() {
  touch "$STATE_FILE"
  sed -i "/^${1}=/d" "$STATE_FILE"
  printf '%s=%s\n' "$1" "$2" >>"$STATE_FILE"
}

load_state() {
  [[ -f "$STATE_FILE" ]] || die "未找到状态文件 $STATE_FILE，请先执行 resolve-input.sh"
  # shellcheck disable=SC1090
  source "$STATE_FILE"
  [[ -n "${ROUND:-}" ]] || die "状态文件内容不完整，请重新执行 resolve-input.sh"
}

need_cmd() { command -v "$1" >/dev/null || die "未安装 $1"; }

need_gh() {
  need_cmd gh
  gh auth status >/dev/null 2>&1 || die "gh 未认证，请提示用户执行: ! gh auth login"
}

# 镜像地址 → 安全文件名
img_slug() { tr '/:@' '___' <<<"$1"; }

# 去掉版本号的 v 前缀（扫描结果里 InstalledVersion 带 v、FixedVersion 不带，需要统一）
ver_norm() { sed 's/^v//' <<<"$1"; }

# ver_ge A B —— A >= B 时返回 0。用 sort -V 做语义版本比较，两侧先去 v 前缀。
ver_ge() {
  local a b
  a="$(ver_norm "$1")"; b="$(ver_norm "$2")"
  [[ "$a" == "$b" ]] && return 0
  [[ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -1)" == "$a" ]]
}

# 预发布版本判定（1.27.0-rc.3 / 1.28.0-beta.1，以及 Go module 的伪版本 v1.2.3-0.2026...）。
# 扫描器会把预发布版当成"修复版本"一起给出来，但它不能用于生产构建，推荐时要先排除。
ver_is_prerelease() { [[ "$(ver_norm "$1")" == *-* ]]; }

# newest_available_patch <MAJOR.MINOR> <起始补丁号>
# 在同一 minor 线上从起始补丁号向上探测，回显 registry 里最新存在的 golang 补丁版本。
# 两个用途：起始版本本身可能 404（上游发了补丁但 mirror 还没同步），
# 以及顺手选到更高的补丁版，省得下次再为新 CVE 升一遍。
# 连续 2 次取不到就停（mirror 的 tag 基本是连着同步的），最多探 10 个，避免慢查询堆积。
# 一个都不存在时回显空串。
newest_available_patch() {
  local mm="$1" start="$2" best="" miss=0 i
  for (( i = 0; i < 10; i++ )); do
    if [[ "$(check_base_image_tag "${mm}.$((start + i))")" == EXISTS ]]; then
      best="${mm}.$((start + i))"; miss=0
    else
      miss=$((miss + 1)); [[ "$miss" -ge 2 ]] && break
    fi
  done
  echo "$best"
}

# 读取流水线实际生效的 Go 构建基础镜像版本（workflow 的 env.BUILD_BASE_IMAGE_VERSION）
workflow_go_version() {
  awk -F':' '/^[[:space:]]+BUILD_BASE_IMAGE_VERSION:/ { gsub(/[[:space:]"]/, "", $2); print $2; exit }' \
    "${1:-$WORKFLOW_FILE}"
}

# 从一次 run 中取出它构建的镜像。
# 流水线用 step 名字 "Output image: <镜像>" 暴露产物，比翻日志稳。
# 注意: 这个 step 是 PR #4（9e9eaaf, 2026-08-11 合入）才加的，在那之前的 run 全都没有——
#       包括 2026-08-10 的 run，别按"2026-08 之后就有"来判断。取不到时返回空，由调用方处理。
extract_run_image() {
  gh run view "$1" --repo "$REPO" --json jobs \
    --jq '.jobs[].steps[] | select(.name | startswith("Output image: ")) | .name | sub("^Output image: "; "")' \
    2>/dev/null | grep -v '^[[:space:]]*$' | sort -u || true
}

# 校验构建基础镜像 golang:<版本> 在 registry 中是否存在，避免流水线到了拉镜像才失败。
# 输出 EXISTS / MISSING / UNKNOWN（registry 偶尔对未缓存的 tag 返回 000，此时不能当作不存在）。
check_base_image_tag() {
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 8 -m 25 \
    -H 'Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json' \
    "${BASE_IMAGE_REGISTRY}/v2/${BASE_IMAGE_PATH}/manifests/$1" 2>/dev/null || echo 000)"
  case "$code" in
    200) echo EXISTS ;;
    404) echo MISSING ;;
    *)   echo "UNKNOWN($code)" ;;
  esac
}

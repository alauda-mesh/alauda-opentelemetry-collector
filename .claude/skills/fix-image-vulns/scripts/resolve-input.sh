#!/usr/bin/env bash
# 步骤 1a：解析输入（流水线 run 或镜像地址）→ 第 1 轮待扫描镜像清单，初始化本次任务状态。
#
# 用法: resolve-input.sh [--force] <RUN_ID|run URL|镜像地址> ...
#   - RUN_ID / run URL：只接受「Alauda Build OpenTelemetry Collector」流水线的成功 run，
#     从 job 里名为 "Output image: <镜像>" 的 step 取产物镜像；
#   - 镜像地址：形如 build-harbor.alauda.cn/asm/opentelemetry-collector:0.158.0-pr.5.15；
#   - 两类可混用，多个输入取并集去重。
# 修复基线 = 主工作区当前检出分支（记入状态，create-fix-branch.sh 使用）。
# --force: 覆盖一个已经建了 PR 的在途任务（默认拒绝，避免误清状态）。
# 退出码: 0=OK  1=失败

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
repo_root
need_cmd jq

FORCE=0
ARGS=()
for a in "$@"; do
  if [[ "$a" == "--force" ]]; then FORCE=1; else ARGS+=("$a"); fi
done
[[ ${#ARGS[@]} -ge 1 ]] || die "用法: resolve-input.sh [--force] <RUN_ID|run URL|镜像地址> ..."

# ---------- 参数分流 ----------
RUNS=(); IMAGES=()
for a in "${ARGS[@]}"; do
  if [[ "$a" =~ /runs/([0-9]+) ]]; then
    RUNS+=("${BASH_REMATCH[1]}")
  elif [[ "$a" =~ ^[0-9]+$ ]]; then
    RUNS+=("$a")
  elif [[ "$a" == */*:* ]]; then
    IMAGES+=("$a")
  else
    die "无法识别的参数: $a（应为 run ID、run URL 或带 tag 的完整镜像地址）"
  fi
done

# ---------- 在途任务保护 ----------
if [[ -f "$STATE_FILE" ]]; then
  OLD_PR="$(sed -n 's/^PR_NUMBER=//p' "$STATE_FILE" | tail -1)"
  if [[ -n "$OLD_PR" && "$FORCE" -eq 0 ]]; then
    die "状态里还有在途任务（PR #$OLD_PR）。要重新开始请确认后加 --force 重跑，
或先用 create-pr.sh / watch-pr.sh 把那个任务收尾。"
  fi
  info "清理上一次任务的状态: $WORK_DIR"
  rm -rf "$WORK_DIR" && mkdir -p "$WORK_DIR"
fi

# ---------- 修复基线 = 当前检出分支 ----------
BASE_BRANCH="$(git branch --show-current)"
[[ -n "$BASE_BRANCH" ]] || die "当前处于 detached HEAD，请先检出一个分支（通常是 main）再重跑"

# ---------- run → 镜像 ----------
if [[ ${#RUNS[@]} -gt 0 ]]; then
  need_gh
  for id in "${RUNS[@]}"; do
    META="$(gh run view "$id" --repo "$REPO" \
      --json workflowName,status,conclusion,displayTitle,headBranch 2>/dev/null)" \
      || die "读取 run $id 失败（--repo $REPO），请确认 run ID 属于本仓库"
    WF="$(jq -r .workflowName <<<"$META")"
    ST="$(jq -r .status <<<"$META")"
    CC="$(jq -r .conclusion <<<"$META")"
    [[ "$WF" == "$WORKFLOW_NAME" ]] \
      || die "run $id 属于工作流「$WF」，本 skill 只处理「$WORKFLOW_NAME」"
    [[ "$ST" == "completed" && "$CC" == "success" ]] \
      || die "run $id 未成功完成（status=$ST conclusion=$CC），镜像可能不存在或不完整，不纳入扫描"

    RUN_IMGS="$(extract_run_image "$id")"
    [[ -n "$RUN_IMGS" ]] || die "run $id 里没有 \"Output image: \" step，取不到镜像。
（该 step 由 PR #4 / 9e9eaaf 在 2026-08-11 引入，更早的 run 都没有，2026-08-10 的也没有）
请直接把镜像地址作为参数传入，例如:
  ${IMAGE_REPO}:<tag>"
    echo "run $id [$(jq -r .displayTitle <<<"$META") @ $(jq -r .headBranch <<<"$META")] 输出镜像:"
    while IFS= read -r img; do
      echo "    $img"
      IMAGES+=("$img")
    done <<<"$RUN_IMGS"
  done
fi

# ---------- 写第 1 轮清单 ----------
[[ ${#IMAGES[@]} -gt 0 ]] || die "没有解析出任何待扫描镜像"
IMG_FILE="$WORK_DIR/images-round1.txt"
printf '%s\n' "${IMAGES[@]}" | sort -u >"$IMG_FILE"

# 本 skill 只修 opentelemetry-collector 镜像；其他镜像不在修复范围内，及早提示
while IFS= read -r img; do
  [[ "${img%%:*}" == "$IMAGE_REPO" ]] \
    || warn "镜像 $img 不是 $IMAGE_REPO，本 skill 的修复手段（BUILD_BASE_IMAGE_VERSION / manifest.yaml replaces）对它无效，只能扫描报告"
done <"$IMG_FILE"

save_state ROUND 1
save_state BASE_BRANCH "$BASE_BRANCH"

echo
echo "INPUT_RESOLVED"
echo "修复基线分支: $BASE_BRANCH"
echo "第 1 轮待扫描镜像:"
sed 's/^/  /' "$IMG_FILE"
echo "下一步: 执行 scan-image.sh（Bash timeout 设 600000）"

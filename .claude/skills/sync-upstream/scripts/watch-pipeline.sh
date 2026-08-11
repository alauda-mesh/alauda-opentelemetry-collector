#!/usr/bin/env bash
# 步骤 4（监控）：轮询 PR 最新 commit 触发的构建流水线直到完成。
# self-hosted runner 上的双平台镜像构建通常需要 10~40 分钟，必须后台运行。
# 可用 WATCH_TIMEOUT（秒，默认 3600）调整超时。
#
# 用法: watch-pipeline.sh
# 退出码: 0=PIPELINE_SUCCESS  2=PIPELINE_FAILED  3=PIPELINE_TIMEOUT  4=PIPELINE_NOT_FOUND

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
repo_root
load_state
need_gh

[[ -n "${PR_NUMBER:-}" ]] || die "状态文件中无 PR_NUMBER，请先执行 create-pr.sh"

TIMEOUT="${WATCH_TIMEOUT:-3600}"
INTERVAL=60
GRACE=300   # 等待流水线出现的宽限期（秒）
START=$(date +%s)

echo "监控 PR #$PR_NUMBER（https://github.com/$REPO/pull/$PR_NUMBER）的流水线，超时 ${TIMEOUT}s ..."

LAST_HEAD=""; HEAD_SEEN_AT=$START; RUNS=""

while true; do
  NOW=$(date +%s); ELAPSED=$((NOW - START))

  # 每轮重取 PR head：监控期间可能 push 了修复 commit。
  # gh 瞬时网络错误只告警重试，不能让 set -e 杀掉整个监控。
  HEAD_OID="$(gh pr view "$PR_NUMBER" --repo "$REPO" --json headRefOid -q .headRefOid 2>/dev/null || true)"
  if [[ -z "$HEAD_OID" ]]; then
    echo "[${ELAPSED}s] WARN: 获取 PR head 失败（gh/网络瞬时错误），${INTERVAL}s 后重试"
    if [[ $ELAPSED -ge $TIMEOUT ]]; then echo "PIPELINE_TIMEOUT"; exit 3; fi
    sleep "$INTERVAL"; continue
  fi
  if [[ "$HEAD_OID" != "$LAST_HEAD" ]]; then
    LAST_HEAD="$HEAD_OID"; HEAD_SEEN_AT=$NOW
  fi
  HEAD_ELAPSED=$((NOW - HEAD_SEEN_AT))

  # 注意: 必须用 workflowName（.name 是 run-name 展示标题，不是 workflow 名）
  RUNS="$(gh run list --repo "$REPO" --commit "$HEAD_OID" \
    --json workflowName,status,conclusion,url,databaseId \
    -q 'sort_by(.databaseId) | .[] | "\(.workflowName)\t\(.status)\t\(.conclusion)\t\(.url)\t\(.databaseId)"' 2>/dev/null || true)"
  # 同名 workflow 取最新一次 run
  RUNS="$(printf '%s\n' "$RUNS" | awk -F'\t' 'NF > 1 { latest[$1] = $0 } END { for (k in latest) print latest[k] }')"

  RUN_COUNT="$(printf '%s\n' "$RUNS" | grep -c . || true)"
  if [[ "$RUN_COUNT" -eq 0 ]]; then
    if [[ $HEAD_ELAPSED -ge $GRACE ]]; then
      echo "PIPELINE_NOT_FOUND"
      echo "等待 ${GRACE}s 后仍未发现 commit ${HEAD_OID:0:8} 触发的流水线。排查方向："
      echo "  1) 本次改动是否命中 workflow 的 paths 过滤（只有 Dockerfile / manifest.yaml / 该 workflow 自身会触发，Makefile 不会）；"
      echo "  2) self-hosted runner 是否在线；"
      echo "  3) PR 的目标分支是否为 main。"
      exit 4
    fi
    echo "[${ELAPSED}s] 尚未发现流水线，继续等待 ..."
    sleep "$INTERVAL"; continue
  fi

  PENDING="$(printf '%s\n' "$RUNS" | awk -F'\t' '$2 != "completed"' | grep -c . || true)"
  echo "[${ELAPSED}s] commit ${HEAD_OID:0:8}: ${RUN_COUNT} 条流水线，${PENDING} 条未完成"
  printf '%s\n' "$RUNS" | awk -F'\t' '{ printf "  - %s: %s %s\n", $1, $2, ($3 == "" ? "-" : $3) }'

  if [[ "$PENDING" -eq 0 ]]; then break; fi
  if [[ $ELAPSED -ge $TIMEOUT ]]; then
    echo "PIPELINE_TIMEOUT"
    printf '%s\n' "$RUNS" | awk -F'\t' '{ print "  - " $1 ": " $4 }'
    exit 3
  fi
  sleep "$INTERVAL"
done

printf '%s\n' "$RUNS" | awk -F'\t' -v w="$WORKFLOW_NAME" '$1 == w' | grep -q . \
  || echo "INFO: 本次未发现名为「${WORKFLOW_NAME}」的 run，请确认 workflow 名是否变更"

FAILED="$(printf '%s\n' "$RUNS" | awk -F'\t' 'NF > 1 && $3 != "success"' || true)"

if [[ -z "$FAILED" ]]; then
  echo "PIPELINE_SUCCESS"
  printf '%s\n' "$RUNS" | awk -F'\t' '{ print "  - " $1 ": success " $4 }'
  RUN_ID="$(printf '%s\n' "$RUNS" | awk -F'\t' -v w="$WORKFLOW_NAME" '$1 == w { print $5; exit }')"
  RUN_NUMBER=""
  if [[ -n "$RUN_ID" ]]; then
    RUN_NUMBER="$(gh run view "$RUN_ID" --repo "$REPO" --json number -q .number 2>/dev/null || true)"
  fi
  if [[ -n "$RUN_NUMBER" ]]; then
    echo "构建镜像: build-harbor.alauda.cn/asm/opentelemetry-collector:${NEW_VERSION}-pr.${PR_NUMBER}.${RUN_NUMBER}"
  else
    echo "构建镜像: build-harbor.alauda.cn/asm/opentelemetry-collector:${NEW_VERSION}-pr.${PR_NUMBER}.<run_number>"
    echo "（run_number 取自流水线运行页面，或 gh run view <run-id> --repo $REPO --json number）"
  fi
  exit 0
fi

echo "PIPELINE_FAILED"
printf '%s\n' "$FAILED" | awk -F'\t' '{ print "  - " $1 ": " $3 " " $4 }'
echo
printf '%s\n' "$FAILED" | while IFS=$'\t' read -r name _ _ _ id; do
  [[ -n "$id" ]] || continue
  echo "===== 失败概览: $name (run $id) ====="
  gh run view "$id" --repo "$REPO" 2>/dev/null | sed -n '1,40p' || echo "(拉取 run 概览失败)"
  echo
  echo "===== 失败日志摘要: $name (run $id) ====="
  LOG="$(gh run view "$id" --repo "$REPO" --log-failed 2>/dev/null || true)"
  if [[ -z "$LOG" ]]; then
    echo "(拉取日志失败，可手动执行: gh run view $id --repo $REPO --log-failed)"
  else
    echo "--- 错误相关行 ---"
    printf '%s\n' "$LOG" | grep -iE "error|fail|fatal|denied|not found|no such|unauthorized|timeout" | tail -30 || true
    echo "--- 日志末尾 ---"
    printf '%s\n' "$LOG" | tail -20
  fi
  echo
done
exit 2

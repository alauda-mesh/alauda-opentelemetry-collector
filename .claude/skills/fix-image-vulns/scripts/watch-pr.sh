#!/usr/bin/env bash
# 步骤 4：监控修复 PR 触发的流水线，成功后收集新镜像供回归扫描。
#
# 用法: watch-pr.sh
# 每轮重取 PR head，所以监控期间 push 修复 commit 也能跟上。
# 成功时把 ROUND +1 并写出 images-round<N+1>.txt。
# self-hosted runner 上的双平台镜像构建通常 10~40 分钟，必须后台运行。
# 退出码: 0=PIPELINE_SUCCESS  2=PIPELINE_FAILED  3=PIPELINE_TIMEOUT  4=PIPELINE_NOT_FOUND  1=前置失败
# 环境变量: WATCH_TIMEOUT=3600

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
repo_root
load_state
need_gh
[[ -n "${PR_NUMBER:-}" ]] || die "状态里没有 PR_NUMBER，请先执行 create-pr.sh"

TIMEOUT="${WATCH_TIMEOUT:-3600}"
INTERVAL=60
GRACE=300           # 等待流水线出现的宽限期
START=$(date +%s)
LAST_HEAD=""; HEAD_SEEN_AT=$START; RUNS=""

echo "监控 PR #$PR_NUMBER（https://github.com/$REPO/pull/$PR_NUMBER）的流水线，超时 ${TIMEOUT}s ..."

while true; do
  NOW=$(date +%s); ELAPSED=$((NOW - START))

  # gh 的瞬时网络错误只告警重试，不能让 set -e 杀掉整个监控
  HEAD_OID="$(gh pr view "$PR_NUMBER" --repo "$REPO" --json headRefOid -q .headRefOid 2>/dev/null || true)"
  if [[ -z "$HEAD_OID" ]]; then
    echo "[${ELAPSED}s] WARN: 获取 PR head 失败（gh/网络瞬时错误），${INTERVAL}s 后重试"
    [[ $ELAPSED -ge $TIMEOUT ]] && { echo "PIPELINE_TIMEOUT"; exit 3; }
    sleep "$INTERVAL"; continue
  fi
  [[ "$HEAD_OID" != "$LAST_HEAD" ]] && { LAST_HEAD="$HEAD_OID"; HEAD_SEEN_AT=$NOW; }
  HEAD_ELAPSED=$((NOW - HEAD_SEEN_AT))

  # 必须用 workflowName（.name 是 run-name 展示标题，不是 workflow 名）
  RUNS="$(gh run list --repo "$REPO" --commit "$HEAD_OID" \
    --json workflowName,status,conclusion,url,databaseId \
    -q 'sort_by(.databaseId) | .[] | "\(.workflowName)\t\(.status)\t\(.conclusion)\t\(.url)\t\(.databaseId)"' 2>/dev/null || true)"
  # 同名 workflow 只保留最新一次 run
  RUNS="$(printf '%s\n' "$RUNS" | awk -F'\t' 'NF > 1 { latest[$1] = $0 } END { for (k in latest) print latest[k] }')"
  RUN_COUNT="$(printf '%s\n' "$RUNS" | grep -c . || true)"

  if [[ "$RUN_COUNT" -eq 0 ]]; then
    if [[ $HEAD_ELAPSED -ge $GRACE ]]; then
      echo "PIPELINE_NOT_FOUND"
      echo "等待 ${GRACE}s 后仍未发现 commit ${HEAD_OID:0:8} 触发的流水线。排查方向："
      echo "  1) 本次改动是否命中 workflow 的 paths 过滤（只有 Dockerfile / manifest.yaml / 该 workflow 自身会触发）；"
      echo "  2) self-hosted runner 是否在线；"
      echo "  3) PR 的目标分支是否正确（本次 base = $BASE_BRANCH）。"
      exit 4
    fi
    echo "[${ELAPSED}s] 尚未发现流水线，继续等待 ..."
    sleep "$INTERVAL"; continue
  fi

  PENDING="$(printf '%s\n' "$RUNS" | awk -F'\t' '$2 != "completed"' | grep -c . || true)"
  echo "[${ELAPSED}s] commit ${HEAD_OID:0:8}: ${RUN_COUNT} 条流水线，${PENDING} 条未完成"
  printf '%s\n' "$RUNS" | awk -F'\t' '{ printf "  - %s: %s %s\n", $1, $2, ($3 == "" ? "-" : $3) }'

  [[ "$PENDING" -eq 0 ]] && break
  if [[ $ELAPSED -ge $TIMEOUT ]]; then
    echo "PIPELINE_TIMEOUT"
    printf '%s\n' "$RUNS" | awk -F'\t' '{ print "  - " $1 ": " $4 }'
    exit 3
  fi
  sleep "$INTERVAL"
done

FAILED="$(printf '%s\n' "$RUNS" | awk -F'\t' 'NF > 1 && $3 != "success"' || true)"
if [[ -n "$FAILED" ]]; then
  echo "PIPELINE_FAILED"
  printf '%s\n' "$FAILED" | awk -F'\t' '{ print "  - " $1 ": " $3 " " $4 }'
  echo
  printf '%s\n' "$FAILED" | while IFS=$'\t' read -r NAME _ _ _ ID; do
    [[ -n "$ID" ]] || continue
    echo "===== 失败概览: $NAME (run $ID) ====="
    gh run view "$ID" --repo "$REPO" 2>/dev/null | sed -n '1,40p' || echo "(拉取 run 概览失败)"
    echo
    echo "===== 失败日志摘要: $NAME (run $ID) ====="
    LOG="$(gh run view "$ID" --repo "$REPO" --log-failed 2>/dev/null || true)"
    if [[ -z "$LOG" ]]; then
      echo "(拉取日志失败，可手动执行: gh run view $ID --repo $REPO --log-failed)"
    else
      echo "--- 错误相关行 ---"
      printf '%s\n' "$LOG" | grep -iE "error|fail|fatal|denied|not found|no such|unauthorized|timeout" | tail -30 || true
      echo "--- 日志末尾 ---"
      printf '%s\n' "$LOG" | tail -20
    fi
    echo
  done
  exit 2
fi

# ---------- 成功：取出新镜像，写回归轮清单 ----------
echo "PIPELINE_SUCCESS"
printf '%s\n' "$RUNS" | awk -F'\t' '{ print "  - " $1 ": success " $4 }'

RUN_ID="$(printf '%s\n' "$RUNS" | awk -F'\t' -v w="$WORKFLOW_NAME" '$1 == w { print $5; exit }')"
[[ -n "$RUN_ID" ]] || die "本次没有发现名为「$WORKFLOW_NAME」的 run，拿不到新镜像。请确认 workflow 名是否变更"

NEXT=$((ROUND + 1))
IMG_FILE="$WORK_DIR/images-round${NEXT}.txt"
extract_run_image "$RUN_ID" >"$IMG_FILE"
if [[ ! -s "$IMG_FILE" ]]; then
  # 兜底：按流水线的 tag 规则拼镜像名（<版本>-pr.<PR号>.<run号>）
  VER="$(awk '/^  version:[[:space:]]/ { print $2; exit }' manifest.yaml)"
  RUN_NUMBER="$(gh run view "$RUN_ID" --repo "$REPO" --json number -q .number 2>/dev/null || true)"
  [[ -n "$VER" && -n "$RUN_NUMBER" ]] \
    || die "run $RUN_ID 里没有 \"Output image: \" step，且无法拼出镜像名，请人工确认后把镜像地址写进 $IMG_FILE"
  echo "${IMAGE_REPO}:${VER}-pr.${PR_NUMBER}.${RUN_NUMBER}" >"$IMG_FILE"
  warn "run 里没有 \"Output image: \" step，已按 tag 规则拼出镜像名，请核对: $(cat "$IMG_FILE")"
fi

save_state ROUND "$NEXT"
echo
echo "构建镜像:"
sed 's/^/  /' "$IMG_FILE"
echo "下一步: 执行 scan-image.sh 做第 ${NEXT} 轮回归扫描（Bash timeout 600000）"

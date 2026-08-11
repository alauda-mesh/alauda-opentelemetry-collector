#!/usr/bin/env bash
# 步骤 4：push 同步分支并创建 PR（幂等：分支已有 open PR 时直接复用）。
#
# 用法: create-pr.sh <PR正文文件>
# 退出码: 0=成功   1=前置条件失败

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
repo_root
load_state
need_gh

BODY_FILE="${1:-}"
[[ -n "$BODY_FILE" && -f "$BODY_FILE" ]] || die "用法: create-pr.sh <PR正文文件>（文件必须存在）"

CUR_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[[ "$CUR_BRANCH" == "$SYNC_BRANCH" ]] || die "当前分支是 $CUR_BRANCH，应在 $SYNC_BRANCH 上执行"
if ! git diff --quiet || ! git diff --cached --quiet; then
  die "有未提交的修改，请先 commit（禁止 amend）"
fi

AHEAD="$(git rev-list --count "origin/main..HEAD")"
[[ "$AHEAD" -gt 0 ]] || die "相对 origin/main 没有任何提交，无需创建 PR"
info "本次 PR 包含 $AHEAD 个提交"

# manifest.yaml 必须在改动里，否则流水线的 paths 过滤不会触发
# （paths 只含 Dockerfile / manifest.yaml / 该 workflow 自身，不含 Makefile）
git diff --name-only "origin/main..HEAD" \
  | grep -qE '^(Dockerfile|manifest\.yaml|\.github/workflows/alauda-build-otelcol\.yaml)$' \
  || warn "本次改动没有命中流水线的 paths 过滤，PR 不会触发构建，请确认是否符合预期"

info "push $SYNC_BRANCH 到 origin ..."
git push -u origin "$SYNC_BRANCH"

EXISTING="$(gh pr list --repo "$REPO" --head "$SYNC_BRANCH" --state open --json number -q '.[0].number' 2>/dev/null || true)"
if [[ -n "$EXISTING" ]]; then
  info "分支已有 open PR #$EXISTING，复用"
  PR_NUMBER="$EXISTING"
else
  gh pr create --repo "$REPO" \
    --base main --head "$SYNC_BRANCH" \
    --title "chore: upgrade to version ${NEW_VERSION}" \
    --body-file "$BODY_FILE" >/dev/null
  PR_NUMBER="$(gh pr list --repo "$REPO" --head "$SYNC_BRANCH" --state open --json number -q '.[0].number')"
fi
[[ -n "$PR_NUMBER" ]] || die "PR 创建后未能查询到编号，请用 gh pr list --repo $REPO 排查"

PR_URL="$(gh pr view "$PR_NUMBER" --repo "$REPO" --json url -q .url)"
save_state PR_NUMBER "$PR_NUMBER"

echo "PR_NUMBER=$PR_NUMBER"
echo "PR_URL=$PR_URL"
echo "下一步: 后台运行 watch-pipeline.sh 监控流水线"

#!/usr/bin/env bash
# 步骤 2a：基于基线分支（resolve-input.sh 记录的 BASE_BRANCH）创建修复分支。
#
# 用法: create-fix-branch.sh
# 分支命名: fix/cve-<UTC日期>
# 幂等：已经在该修复分支上时直接复用（回归轮追加 commit 用）。
# 输出: BRANCH= / BASE=
# 退出码: 0=OK  1=失败（工作区不干净、基线分支领先 origin 等，需人工确认）

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
repo_root
load_state
[[ -n "${BASE_BRANCH:-}" ]] || die "状态里没有 BASE_BRANCH，请先执行 resolve-input.sh"

FIX_BRANCH="fix/cve-$(date -u +%Y%m%d)"
CUR="$(git branch --show-current || true)"

# 已经在修复分支上：回归轮重跑，直接复用
if [[ "$CUR" == "$FIX_BRANCH" ]]; then
  info "已在修复分支 $FIX_BRANCH 上，直接复用"
  save_state FIX_BRANCH "$FIX_BRANCH"
  echo "BRANCH_READY"
  echo "BRANCH=$FIX_BRANCH"
  echo "BASE=$BASE_BRANCH"
  exit 0
fi

[[ -z "$(git status --porcelain)" ]] \
  || die "工作区有未提交改动，创建修复分支会把它们带进 PR。请先提交或 stash 后重跑:
$(git status --short)"

[[ "$CUR" == "$BASE_BRANCH" ]] \
  || die "当前分支是 $CUR，与状态里的基线分支 $BASE_BRANCH 不一致。
请切回 $BASE_BRANCH，或重新执行 resolve-input.sh 以当前分支为基线。"

# 基线分支与 origin 的领先/落后检查：领先说明有未 push 的 commit，会一起混进修复 PR
if git fetch -q origin "refs/heads/$BASE_BRANCH:refs/remotes/origin/$BASE_BRANCH" 2>/dev/null; then
  AHEAD="$(git rev-list --count "refs/remotes/origin/$BASE_BRANCH..HEAD")"
  BEHIND="$(git rev-list --count "HEAD..refs/remotes/origin/$BASE_BRANCH")"
  [[ "$AHEAD" -gt 0 ]] && die "本地 $BASE_BRANCH 领先 origin $AHEAD 个 commit，
基于它建修复分支会把这些未 push 的 commit 一并带进 PR。请先 push 或与用户确认后重跑。"
  [[ "$BEHIND" -gt 0 ]] && warn "本地 $BASE_BRANCH 落后 origin $BEHIND 个 commit，修复将基于本地旧基线（需要最新代码就先 git pull 再重跑 resolve-input.sh）"
else
  warn "fetch origin/$BASE_BRANCH 失败，跳过领先/落后检查"
fi

if git rev-parse --verify --quiet "refs/heads/$FIX_BRANCH" >/dev/null; then
  warn "本地已存在分支 $FIX_BRANCH（可能是上次中断留下的），直接检出复用，其历史提交保留"
  git checkout -q "$FIX_BRANCH"
else
  git checkout -q -b "$FIX_BRANCH"
fi

save_state FIX_BRANCH "$FIX_BRANCH"

echo "BRANCH_READY"
echo "BRANCH=$FIX_BRANCH"
echo "BASE=$BASE_BRANCH（$(git rev-parse --short "refs/heads/$BASE_BRANCH")）"
echo "下一步: 按修复目标执行 apply-fix.sh"

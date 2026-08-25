#!/usr/bin/env bash
# 步骤 1b / 步骤 5：调内网服务扫描当前轮镜像，按修复责任分类并聚合出修复目标。
#
# 用法: scan-image.sh [轮次]      # 缺省用状态里的 ROUND
# 分类:
#   OS_REPORT   基础镜像的 os 包       → 不修复，如实报告
#   GO_STDLIB   Go 标准库              → 升 workflow 的 BUILD_BASE_IMAGE_VERSION
#   GO_MODULE   Go 依赖库              → manifest.yaml 加 replaces 钉到修复版本
#   UNKNOWN     解析不出包名           → 人工判断
# 输出: 每镜像明细 + 修复目标（可直接抄成 apply-fix.sh 参数）+ SUMMARY
#       + RESULT: CLEAN | REPORT_ONLY | FIX_NEEDED
#       Go 漏洞为 0 时额外输出一条反证: CONTROL: OK|SUSPECT|UNVERIFIED
# 退出码: 0=扫描完成（无论结论）  1=失败
# 注意: 服务端要先拉镜像再扫，单个镜像可能几分钟，调用方把 Bash timeout 设为 600000。
#       Go 漏洞为 0 时还会多扫一个对照镜像，耗时翻倍，timeout 别调小。
# 环境变量: SCAN_API（跳过主备探测直接指定）、MAX_ATTEMPTS=3、RETRY_DELAY=15、SCAN_TIMEOUT=600、
#           CONTROL_IMAGE（对照镜像，默认 docker-mirrors.alauda.cn/library/golang:1.21）

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
repo_root
load_state
need_cmd jq

MAX_ATTEMPTS="${MAX_ATTEMPTS:-3}"
RETRY_DELAY="${RETRY_DELAY:-15}"
SCAN_TIMEOUT="${SCAN_TIMEOUT:-600}"

N="${1:-$ROUND}"
IMG_FILE="$WORK_DIR/images-round${N}.txt"
[[ -s "$IMG_FILE" ]] || die "没有第 ${N} 轮镜像清单: $IMG_FILE（第 1 轮先跑 resolve-input.sh，回归轮先跑 watch-pr.sh）"

# ---------- 选定扫描服务 ----------
# 能返回任意 HTTP 状态码就算在线（连接被拒/超时会得到 000）
probe() {
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 -m 10 "$1/" 2>/dev/null || true)"
  [[ -n "$code" && "$code" != "000" ]]
}
APIS=()
if [[ -n "${SCAN_API:-}" ]]; then
  APIS=("$SCAN_API"); info "使用显式指定的扫描服务: $SCAN_API"
elif probe "$SCAN_API_PRIMARY"; then
  APIS=("$SCAN_API_PRIMARY" "$SCAN_API_BACKUP")
  info "使用主扫描服务: $SCAN_API_PRIMARY（备用: $SCAN_API_BACKUP）"
elif probe "$SCAN_API_BACKUP"; then
  APIS=("$SCAN_API_BACKUP"); warn "主扫描服务不可达（$SCAN_API_PRIMARY），切换到备用: $SCAN_API_BACKUP"
else
  die "主备扫描服务均不可达: $SCAN_API_PRIMARY / $SCAN_API_BACKUP"
fi

SCAN_DIR="$WORK_DIR/scans/round${N}"
mkdir -p "$SCAN_DIR"
TSV="$SCAN_DIR/vulns.tsv"
: >"$TSV"

# ---------- 逐镜像扫描 ----------
API_IDX=0
while IFS= read -r IMG; do
  [[ -n "$IMG" ]] || continue
  OUT="$SCAN_DIR/$(img_slug "$IMG").json"
  ENC="$(jq -rn --arg v "$IMG" '$v|@uri')"
  info "扫描 $IMG ..."

  RESP=""
  while [[ -z "$RESP" && "$API_IDX" -lt ${#APIS[@]} ]]; do
    API="${APIS[$API_IDX]}"
    URL="${API}/image/vulnerability/custom?image_full_address=${ENC}&trivy_db_date=latest&severity=low&vulnerability_type=os%2Clibrary&version=v4.4.0"
    for i in $(seq 1 "$MAX_ATTEMPTS"); do
      # 镜像不存在时服务返回 5xx + {"error": "..."}，--fail 能拦住，不会被当成"没有漏洞"
      if RESP="$(curl -sS --fail --max-time "$SCAN_TIMEOUT" -H 'accept: application/json' "$URL" 2>/dev/null)" \
         && jq -e 'has("os") and has("lang")' <<<"$RESP" >/dev/null 2>&1; then
        break
      fi
      RESP=""
      [[ "$i" -lt "$MAX_ATTEMPTS" ]] && { warn "扫描失败，${RETRY_DELAY}s 后重试（$i/$MAX_ATTEMPTS）"; sleep "$RETRY_DELAY"; }
    done
    if [[ -z "$RESP" ]]; then
      API_IDX=$((API_IDX + 1))
      [[ "$API_IDX" -lt ${#APIS[@]} ]] && warn "服务 $API 连续 $MAX_ATTEMPTS 次失败，切换到 ${APIS[$API_IDX]}"
    fi
  done
  [[ -n "$RESP" ]] || die "所有扫描服务均连续失败: $IMG
（若是镜像不存在，服务会返回 MANIFEST_UNKNOWN，请核对镜像 tag）"
  printf '%s\n' "$RESP" >"$OUT"

  # TSV 列: 分类 / 包 / 装机版本(去v) / 修复候选(逗号分隔,去v) / CVE / 严重度 / 目标
  # 注: 服务对"无修复版本"可能返回字符串 "null"，必须当空处理，否则会算出 @vnull 的假目标
  ROWS="$(jq -r '
    def fixes: [ (.FixedVersion // "") | split(",")[] | gsub("^\\s+|\\s+$";"")
                 | sub("^v";"") | select(. != "" and . != "null") ] | unique | join(",");
    def cat: if (.PkgName // "") == "stdlib" then "GO_STDLIB"
             elif (.PkgName // "") == "" then "UNKNOWN"
             else "GO_MODULE" end;
    ( [ (.os   // [])[] | . + {__cat: "OS_REPORT"} ]
    + [ (.lang // [])[] | . + {__cat: cat} ] )
    | .[]
    | [ .__cat, (.PkgName // "?"), ((.InstalledVersion // "?") | sub("^v";"")),
        fixes, (.VulnerabilityID // "?"), (.Severity // "?"), (.Target // "-") ]
    | @tsv' "$OUT" | sort -u)"

  CNT=0
  if [[ -n "$ROWS" ]]; then
    printf '%s\n' "$ROWS" >>"$TSV"
    CNT="$(grep -c . <<<"$ROWS")"
  fi
  echo
  echo "--- $IMG（漏洞 ${CNT} 条）---"
  [[ -n "$ROWS" ]] && awk -F'\t' \
    '{ printf "  [%s] %s %s %s 当前 %s → 修复版本 %s\n", $1, $2, $5, $6, $3, ($4 == "" ? "（无）" : $4) }' \
    <<<"$ROWS"
done <"$IMG_FILE"

sort -u "$TSV" -o "$TSV"
count_cat() { awk -F'\t' -v c="$1" '$1 == c' "$TSV" | grep -c . || true; }
TOTAL="$(grep -c . "$TSV" || true)"
STDLIB_N="$(count_cat GO_STDLIB)"; GOMOD_N="$(count_cat GO_MODULE)"
OS_N="$(count_cat OS_REPORT)";     UNK_N="$(count_cat UNKNOWN)"

# ---------- 假阴性守卫 ----------
# 镜像里是一个 180MB 的 Go 二进制，Go 依赖漏洞为 0 有两种可能：
#   (a) 真的干净；
#   (b) 扫描服务/漏洞库出问题，对什么镜像都返回空。
# 扫描 API 的 os/lang 数组里只装漏洞、不装包清单，所以「0 条」自己证明不了自己，
# 下面的对照扫描反证 (b)：拿一个必定有漏洞的公共镜像走同一条链路，看服务与漏洞库是不是好的。
if [[ "$STDLIB_N" -eq 0 && "$GOMOD_N" -eq 0 && "$UNK_N" -eq 0 ]]; then
  echo
  echo "--- 对照扫描（反证扫描链路可用）---"
  CTRL_ENC="$(jq -rn --arg v "$CONTROL_IMAGE" '$v|@uri')"
  CTRL_URL="${APIS[$API_IDX]}/image/vulnerability/custom?image_full_address=${CTRL_ENC}&trivy_db_date=latest&severity=low&vulnerability_type=os%2Clibrary&version=v4.4.0"
  CTRL_RESP="$(curl -sS --fail --max-time "$SCAN_TIMEOUT" -H 'accept: application/json' "$CTRL_URL" 2>/dev/null || true)"
  CTRL_N="$(jq -r '((.os // []) | length) + ((.lang // []) | length)' <<<"${CTRL_RESP:-{\}}" 2>/dev/null || echo 0)"
  if [[ -z "$CTRL_RESP" ]]; then
    warn "对照镜像 $CONTROL_IMAGE 扫描请求失败，无法反证链路可用，本次 0 条结果存疑。"
    echo "CONTROL: UNVERIFIED"
  elif [[ "$CTRL_N" -gt 0 ]]; then
    echo "  对照镜像 $CONTROL_IMAGE 扫出 ${CTRL_N} 条漏洞，扫描服务与漏洞库正常。"
    echo "CONTROL: OK"
  else
    warn "对照镜像 $CONTROL_IMAGE 也扫出 0 条——扫描服务或漏洞库异常，"
    warn "本次「无漏洞」不可信，不要据此判定镜像干净！"
    echo "CONTROL: SUSPECT"
  fi
fi

# ---------- 聚合修复目标 ----------
if [[ "$STDLIB_N" -gt 0 || "$GOMOD_N" -gt 0 ]]; then
  WF_GO="$(workflow_go_version)"
  echo
  echo "--- 修复目标（基线分支 ${BASE_BRANCH}，当前 BUILD_BASE_IMAGE_VERSION=${WF_GO:-未知}）---"

  if [[ "$STDLIB_N" -gt 0 ]]; then
    INST="$(awk -F'\t' '$1 == "GO_STDLIB" { print $3; exit }' "$TSV")"
    CANDS="$(awk -F'\t' '$1 == "GO_STDLIB" { print $4 }' "$TSV" | tr ',' '\n' | grep -v '^$' | sort -uV || true)"
    if [[ -z "$CANDS" ]]; then
      echo "  [stdlib] 当前 go ${INST}  CVE×${STDLIB_N}  （无修复版本，升级修不了，如实汇报）"
    else
      echo "  [stdlib] 当前 go ${INST}  CVE×${STDLIB_N}  修复候选: $(paste -sd'/' - <<<"$CANDS")"
      # 候选里混着三类不能用的东西，简单"取最高"会选错，逐层筛掉：
      #   1) 预发布版（如 1.27.0-rc.3，还常常在 mirror 里根本不存在）——不用于生产构建；
      #   2) 低于当前版本的（当前 1.26.5 时的 1.25.13 是旧 minor 线的补丁）——升上去等于降级；
      #   3) registry 里不存在的 tag——流水线要跑到拉镜像才失败，白等一轮。
      USABLE=""
      while IFS= read -r C; do
        [[ -n "$C" ]] || continue
        if ver_is_prerelease "$C"; then
          echo "           - 排除 $C：预发布版本，不用于生产构建"
        elif ! ver_ge "$C" "$INST"; then
          echo "           - 排除 $C：低于当前 go ${INST}，升上去等于降级"
        else
          USABLE+="${C}"$'\n'
        fi
      done <<<"$CANDS"
      USABLE="$(grep -v '^$' <<<"$USABLE" | sort -uV || true)"

      if [[ -z "$USABLE" ]]; then
        echo "           （候选全被排除：只有预发布版或降级版本，这条修不了，如实汇报让用户决策）"
      else
        # 同 minor 线优先：补丁升级的风险远低于跨次版本。只能跨 minor 时取最低的那个。
        MM="$(cut -d. -f1-2 <<<"$INST")"
        PICK="$(awk -v mm="${MM}." 'index($0, mm) == 1' <<<"$USABLE" | tail -1)"
        CROSS_MINOR=0
        [[ -n "$PICK" ]] || { PICK="$(head -1 <<<"$USABLE")"; CROSS_MINOR=1; }

        info "探测 ${BASE_IMAGE_PATH} 在 $BASE_IMAGE_REGISTRY 上从 $PICK 起可用的补丁版 ..."
        NEWEST="$(newest_available_patch "$(cut -d. -f1-2 <<<"$PICK")" "$(cut -d. -f3 <<<"$PICK")")"
        if [[ -z "$NEWEST" ]]; then
          echo "           ! ${BASE_IMAGE_PATH}:${PICK} 及其后续补丁版在 $BASE_IMAGE_REGISTRY 上都不存在"
          echo "             （上游发了补丁版但 mirror 还没同步）这条 stdlib 漏洞暂时修不了，"
          echo "             把原因如实汇报给用户决策，不要硬凑一个版本。"
        else
          echo "           → apply-fix.sh --go ${NEWEST}"
          [[ "$NEWEST" != "$PICK" ]] \
            && echo "             （最小可覆盖版本是 ${PICK}，${NEWEST} 是 $(cut -d. -f1-2 <<<"$PICK") 线上 registry 里最新的可用补丁版）"
          [[ "$CROSS_MINOR" -eq 1 ]] \
            && echo "             ! 跨 Go 次版本（${INST} → ${NEWEST}）：同 minor 线没有可用候选，最终报告里要着重说明"
        fi
      fi
    fi
  fi

  while IFS= read -r PKG; do
    INST="$(awk -F'\t' -v p="$PKG" '$1 == "GO_MODULE" && $2 == p { print $3; exit }' "$TSV")"
    N_FIX="$(awk -F'\t' -v p="$PKG" '$1 == "GO_MODULE" && $2 == p && $4 != "" { print $5 }' "$TSV" | sort -u | grep -c . || true)"
    N_NOFIX="$(awk -F'\t' -v p="$PKG" '$1 == "GO_MODULE" && $2 == p && $4 == "" { print $5 }' "$TSV" | sort -u | grep -c . || true)"
    CVES="$(awk -F'\t' -v p="$PKG" '$1 == "GO_MODULE" && $2 == p && $4 != "" { print $5 }' "$TSV" | sort -u | paste -sd',' -)"
    CANDS="$(awk -F'\t' -v p="$PKG" '$1 == "GO_MODULE" && $2 == p { print $4 }' "$TSV" | tr ',' '\n' | grep -v '^$' | sort -uV || true)"
    if [[ -n "$CANDS" ]]; then
      echo "  [go.mod] $PKG 当前 v${INST}  CVE×${N_FIX}$([[ "$N_NOFIX" -gt 0 ]] && echo "（另有 ${N_NOFIX} 个无修复版本）")  候选: $(paste -sd'/' - <<<"$CANDS")"
      # 预发布版/伪版本不适合钉；只有当候选里还剩正式版时才排除它们
      # 注: 循环体末尾不能留 `[[ ... ]] && ...` 这种可能返回非零的写法，set -e 会把子 shell 提前掐断
      REAL="$(while IFS= read -r C; do ver_is_prerelease "$C" || printf '%s\n' "$C"; done <<<"$CANDS" \
              | grep -v '^$' | sort -uV || true)"
      if [[ -n "$REAL" ]]; then
        PICK="$(tail -1 <<<"$REAL")"
      else
        PICK="$(tail -1 <<<"$CANDS")"
        echo "           ! 候选里只有预发布版/伪版本，钉它有风险，先人工确认"
      fi
      # replace 是精确钉版本：目标要取 max(修复候选, 产物里当前版本)，否则会把依赖降级
      if ! ver_ge "$PICK" "$INST"; then
        echo "           ! 最高候选 v${PICK} 低于产物里的 v${INST}（多条 minor 线各自发补丁导致），"
        echo "             钉 v${PICK} 会降级。请人工确认该 CVE 在 v${INST} 上的真实修复版本再定。"
        PICK="$INST"
      fi
      echo "           → apply-fix.sh --replace '${PKG}@v${PICK}#${CVES}'"
    else
      echo "  [go.mod] $PKG 当前 v${INST}  CVE×${N_NOFIX}  （无修复版本，升级修不了，如实汇报）"
    fi
  done < <(awk -F'\t' '$1 == "GO_MODULE" { print $2 }' "$TSV" | sort -u)
fi

echo
echo "SUMMARY: ROUND=${N} TOTAL=${TOTAL} GO_STDLIB=${STDLIB_N} GO_MODULE=${GOMOD_N} OS_REPORT=${OS_N} UNKNOWN=${UNK_N}"

# 可执行修复 = 有修复候选的 Go 漏洞，或需要人工判断的 UNKNOWN
FIXABLE="$(awk -F'\t' '(($1 == "GO_STDLIB" || $1 == "GO_MODULE") && $4 != "") || $1 == "UNKNOWN"' "$TSV" | grep -c . || true)"
if [[ "$TOTAL" -eq 0 ]]; then
  echo "RESULT: CLEAN"
elif [[ "$FIXABLE" -gt 0 ]]; then
  echo "RESULT: FIX_NEEDED"
else
  echo "RESULT: REPORT_ONLY（剩余全是不修复项：os 级漏洞 / 无修复版本的条目）"
fi
echo "明细: $TSV"

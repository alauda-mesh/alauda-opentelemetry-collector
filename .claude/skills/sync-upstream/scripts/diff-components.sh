#!/usr/bin/env bash
# 步骤 3：对比本仓库 manifest.yaml 与 OCP main 的 manifest.yaml 的 OTel 组件列表。
# 应在步骤 2 的跟进改动完成之后运行，这样差异清单里剩下的才是真正待决策的项。
#
# 用法: diff-components.sh
# 退出码: 0=成功   1=前置条件失败

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
repo_root
need_cmd curl

OCP_MANIFEST="$WORK_DIR/ocp-manifest.yaml"
fetch "https://raw.githubusercontent.com/${OCP_REPO}/main/manifest.yaml" "$OCP_MANIFEST"

ACP_VERSION="$(manifest_version manifest.yaml)"
OCP_VERSION="$(manifest_version "$OCP_MANIFEST")"

ACP_LIST="$WORK_DIR/acp-components.txt"
OCP_LIST="$WORK_DIR/ocp-components.txt"
manifest_components manifest.yaml | sort >"$ACP_LIST"
manifest_components "$OCP_MANIFEST" | sort >"$OCP_LIST"

[[ -s "$ACP_LIST" ]] || die "解析本仓库 manifest.yaml 组件失败"
[[ -s "$OCP_LIST" ]] || die "解析 OCP manifest.yaml 组件失败"

# 以 "section module" 为主键比对（版本差异单独处理）
awk '{ print $1, $2 }' "$ACP_LIST" | sort -u >"$WORK_DIR/acp-keys.txt"
awk '{ print $1, $2 }' "$OCP_LIST" | sort -u >"$WORK_DIR/ocp-keys.txt"

# 有些组件在 OCP 侧不是"加一行 gomod 就行"：带 import: 续行（模块路径 != 组件包路径），
# 或在 replaces: 里被重定向到本地源码目录（如 obi => ../.obi-src，需要额外 clone 源码）。
# 这类必须标出来，否则照抄一行会直接构建失败。
SPECIAL="$WORK_DIR/ocp-special-modules.txt"
awk '
  /^[a-z_]+:[[:space:]]*$/ { section = substr($0, 1, index($0, ":") - 1); next }
  section == "replaces" && $1 == "-" && NF >= 2 { print $2 "\treplaces"; next }
  $1 == "-" && $2 == "gomod:" && NF == 4 { lastmod = $3; next }
  $1 == "import:" && lastmod != "" { print lastmod "\timport"; lastmod = "" }
' "$OCP_MANIFEST" | sort -u >"$SPECIAL"

echo "=== 版本 ==="
echo "  ACP manifest dist.version: $ACP_VERSION   （组件 $(wc -l <"$ACP_LIST") 个）"
echo "  OCP manifest dist.version: $OCP_VERSION   （组件 $(wc -l <"$OCP_LIST") 个）"
if [[ "$ACP_VERSION" != "$OCP_VERSION" ]]; then
  echo
  warn "两侧 collector 版本不同，逐模块的版本号差异属预期，本脚本不再逐条列出，只对比组件增减。"
fi
echo

# ---------- 仅 OCP 有 ----------
ONLY_OCP="$(comm -13 "$WORK_DIR/acp-keys.txt" "$WORK_DIR/ocp-keys.txt")"
N_ONLY_OCP="$(printf '%s\n' "$ONLY_OCP" | grep -c . || true)"
echo "=== 仅 OCP 有 / ACP 缺少：$N_ONLY_OCP 个 ==="
if [[ "$N_ONLY_OCP" -eq 0 ]]; then
  echo "  （无）"
else
  echo "  下方每项给出可直接粘贴进 manifest.yaml 对应段落的行；带 ⚠ 的不能只粘这一行。"
  printf '%s\n' "$ONLY_OCP" | grep . | awk -v listfile="$OCP_LIST" -v specialfile="$SPECIAL" '
    BEGIN {
      while ((getline l < listfile) > 0) {
        split(l, a, " ")
        ver[a[1] " " a[2]] = a[3]
      }
      close(listfile)
      # 不能用三元表达式：mawk 会先把 special[b[1]] 建出来，导致 in 判断恒真、多出前导 "+"
      while ((getline s < specialfile) > 0) {
        split(s, b, "\t")
        if (b[1] in special) special[b[1]] = special[b[1]] "+" b[2]
        else special[b[1]] = b[2]
      }
      close(specialfile)
      idx = 0
    }
    {
      key = $1 " " $2
      idx++
      if ($1 != lastsec) { printf "\n  [%s]\n", $1; lastsec = $1 }
      printf "   [%d] - gomod: %s %s\n", idx, $2, ver[key]
      if ($2 in special) {
        printf "        ⚠ OCP 侧该模块还配了 %s，只加这一行会构建失败，需要连带处理\n", special[$2]
      }
    }
  '
fi
echo

# ---------- 仅 ACP 有 ----------
ONLY_ACP="$(comm -23 "$WORK_DIR/acp-keys.txt" "$WORK_DIR/ocp-keys.txt")"
N_ONLY_ACP="$(printf '%s\n' "$ONLY_ACP" | grep -c . || true)"
echo "=== 仅 ACP 有 / OCP 没有：$N_ONLY_ACP 个 ==="
if [[ "$N_ONLY_ACP" -eq 0 ]]; then
  echo "  （无）"
else
  echo "  这些是 ACP 自己的选择，通常保留；若 OCP 是主动移除的，需要判断原因。"
  printf '%s\n' "$ONLY_ACP" | grep . | awk '{ printf "    [%s] %s\n", $1, $2 }'
fi
echo

# ---------- 共有模块的版本差异 ----------
echo "=== 共有模块的版本差异 ==="
if [[ "$ACP_VERSION" != "$OCP_VERSION" ]]; then
  echo "  （两侧 collector 版本不同，已跳过；把 ACP 升到与 OCP 同版本后再看这一节才有意义）"
else
  DIFFS="$(join -j 1 -o 0,1.2,2.2 \
    <(awk '{ print $1 "/" $2, $3 }' "$ACP_LIST" | sort) \
    <(awk '{ print $1 "/" $2, $3 }' "$OCP_LIST" | sort) \
    | awk '$2 != $3 { printf "    %s: ACP=%s  OCP=%s\n", $1, $2, $3 }')"
  if [[ -z "$DIFFS" ]]; then
    echo "  （无，两侧共有模块版本完全一致）"
  else
    echo "  以下模块两侧版本不同，需要人工判断（正常情况下应为空）："
    printf '%s\n' "$DIFFS"
  fi
fi

echo
echo "=== 提示 ==="
echo "步骤 2 中 MANIFEST_COMPONENT 类提交引入的组件会出现在\"仅 OCP 有\"里；"
echo "生成 review 报告时，对已在步骤 2 决策过的编号标注\"已在步骤2处理\"，不要让用户重复 review。"

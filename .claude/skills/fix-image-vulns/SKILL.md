---
name: fix-image-vulns
description: 修复 alauda-mesh/alauda-opentelemetry-collector 的「Alauda Build OpenTelemetry Collector」流水线构建的 opentelemetry-collector 镜像漏洞。输入一个流水线 run（ID/URL）或完整镜像地址，完成：解析待扫镜像、调内网扫描服务扫描并按修复责任分类、修复（Go 标准库 → 升 workflow 的 BUILD_BASE_IMAGE_VERSION；Go 依赖库 → 在 manifest.yaml 加 replaces）、本地 make build 并校验修复是否真的落到产物上、创建 PR 并监控流水线、回归扫描（最多 3 轮修复）；os 级漏洞只扫描报告不修复。仅限用户显式通过 /fix-image-vulns 调用。
argument-hint: "[RUN_ID | run URL | 镜像地址]，例如: /fix-image-vulns 31468229342"
disable-model-invocation: true
---

# 修复 otelcol 镜像漏洞

对流水线构建的 opentelemetry-collector 镜像做漏洞扫描，按修复责任分类处理，直到镜像干净或达到轮次上限。
下文的 `$SKILL_DIR` 指本 skill 的根目录（即调用时提示的 Base directory）。

## 参数

- `$ARGUMENTS`：流水线 run（纯数字 ID 或 run URL，只接受**成功**的「Alauda Build OpenTelemetry Collector」run）
  或带 tag 的完整镜像地址（如 `build-harbor.alauda.cn/asm/opentelemetry-collector:0.158.0-pr.5.15`），两类可混用。
- 参数里可能混着给你的备注文字，只把 run/镜像部分传给脚本，备注按用户的附加要求执行。
- 参数为空时用 AskUserQuestion 问用户，不要自行猜测或随便挑一个 run。

## 背景知识

**本仓库没有 Go 源码**，也就没有可以直接 `go get` 的 `go.mod`：`manifest.yaml` 是 ocb 的组件清单，
ocb 按它生成 `_build/go.mod` 再编译。所以修依赖漏洞的手段是往 `manifest.yaml` 加 `replaces`，
不是改 go.mod——改了也会被下次构建覆盖。

**两个修复杠杆，对应两类漏洞**：

| 漏洞类别 | 判据 | 修复手段 |
| --- | --- | --- |
| Go 标准库 | 扫描结果 `PkgName == "stdlib"` | 升 `.github/workflows/alauda-build-otelcol.yaml` 的 `env.BUILD_BASE_IMAGE_VERSION`（构建用的 golang 镜像版本） |
| Go 依赖库 | 扫描结果里其他 lang 条目 | `manifest.yaml` 的 `replaces:` 段把该模块钉到修复版本 |
| os 级 | 扫描结果的 `os` 数组 | **不修复**，如实报告（基础镜像是 `mlops/static`，这类漏洞归基础镜像维护方） |

**判断依据与坑**：

- `replaces` 是**精确钉版本**，比当前解析到的版本低就会造成降级。目标版本取
  `max(扫描给的修复版本, 产物里当前的版本)`；`apply-fix.sh` 会拿 `_build/go.mod` 对比并告警。
- 依赖之间有约束，实际落位版本可能高于扫描给的修复候选，属正常。以 `build-verify.sh` 的落位校验为准。
- 若有漏洞的模块是 **OTel Collector 自己的组件**（`go.opentelemetry.io/collector/*`、
  `github.com/open-telemetry/opentelemetry-collector-contrib/*`），它们是**成套发布**的，
  单独 replace 一个很容易编译不过。这种情况的正解通常是整体升级 collector 版本（走 `/sync-upstream`），
  先把分析结论告诉用户再决定，不要硬钉。
- 扫描结果里 `InstalledVersion` 带 `v` 前缀、`FixedVersion` 不带，拼 `--replace` 参数时要补上 `v`。
- **修复候选不能直接"取最高"，也不能挑字面第一个。** 扫描器给的 `FixedVersion` 里混着三类东西：
  预发布版（`1.27.0-rc.3`，不能用于生产构建，而且 mirror 里常常压根不存在）、
  旧 minor 线的补丁版（当前 1.26.5 时给的 `1.25.13`，升上去等于降级）、以及真正可用的版本。
  `scan-image.sh` 现在会自动排除前两类、同 minor 线优先、再探测 registry 上从该版本起最新的可用补丁版，
  直接吐出一行可以照抄的 `→ apply-fix.sh --go <版本>`。**照它给的执行，不要自己回候选列表里挑。**
- **每条 CVE 的候选列表不一定相同**，定了版本要回头核对它覆盖了**每一条**。
  实测 0.158.0：8 条 stdlib CVE 里 7 条 1.25.13 就能修，但 CVE-2026-46600 要 ≥1.26.6。
- 构建基础镜像的目标 tag 必须在 `docker-mirrors.alauda.cn` 里真的存在，`apply-fix.sh` 会先查，
  404 直接拒绝，免得流水线跑到拉镜像才失败。**这是个常见情况**：Go 刚发新补丁版、扫描器已经把它
  当修复版本了，但镜像仓库还没同步。哪个版本 404 是会变的（2026-08-25 实测 `1.26.6`/`1.26.7`/`1.27.0`
  都在，而 `1.26.8`、`1.27.0-rc.3` 是 404），别把某个具体版本当结论，以 `newest_available_patch` 的实测为准。
  如果压根没有更高的可用版本，就不要硬凑——把这条 stdlib 漏洞记进"暂时修不了"，
  说明原因（上游补丁版镜像未同步）让用户决策。
- **`Dockerfile` 的 `ARG BUILD_BASE_IMAGE_VERSION` 与 workflow 的 `env` 会长期不同步**
  （实测 Dockerfile 停在 1.26.1、workflow 已是 1.26.5，因为流水线用 build-arg 覆盖，Dockerfile 那个值只影响本地
  `docker build`）。`apply-fix.sh` 会把两边一起对齐到目标版本，所以 diff 里 Dockerfile 的跨度会比 workflow 大——
  写报告时按各自的实际旧值写，别以为两边是从同一个版本升上来的。
- 流水线的 `paths` 过滤只含 `Dockerfile` / `manifest.yaml` / 该 workflow 自身。两类修复都命中，
  但如果最后只提交了无关文件，PR 不会构建，也就没有新镜像可回归扫描。
- **构建期间不要去读 `_build/go.mod`**：ocb 先写一个最小 go.mod 再交给 `go mod tidy` 补全，
  中途读到的是中间态。要看依赖版本等 `build-verify.sh` 跑完。
- **`pull_request` 的 `paths` 过滤是按整个 PR diff 判定的，不是按这一次 push 改了哪些文件。**
  修复 PR 里已经改过 `Dockerfile` / `manifest.yaml`，那么之后哪怕只 push 一个纯文档改动，
  synchronize 事件照样命中过滤、照样把双平台镜像重新构建一遍
  （实测 2026-08-25：往 PR #6 追加一个只动 `.claude/**` 和 `README.md` 的 commit，
  触发了新 run 32803862571）。
- **正因如此，监控流水线期间不要往修复分支 push 任何无关改动**（顺手提交的 skill 改动、README 之类）：
  `watch-pr.sh` 每轮重取 PR head，head 一变就转去盯新 commit 的 run，上一轮快跑完的构建白等，
  还多烧一次双平台构建。无关改动要么并进第一个 commit 一起提，要么等整轮跑完再 push。
  （反过来，如果 PR 从头到尾只有无关文件，那就一次 run 都不会有，`watch-pr.sh` 在宽限期后报
  PIPELINE_NOT_FOUND，`create-pr.sh` 对这种情况提前有 warn。）
- git 规矩：**禁止 `git commit --amend`**，一律新建 commit；message 不要带 `Co-Authored-By` /
  `Claude-Session`。`gh` 命令必须显式 `--repo alauda-mesh/alauda-opentelemetry-collector`（脚本已内置）。
- 修复轮次上限 **3 轮**（首轮 + 回归后最多再修 2 次），修不完就如实汇报，让用户决策。
- 各脚本的中间产物（扫描 JSON、分类 TSV、构建日志、步骤间状态）都在 `.git/otel-vulnfix/` 下，
  不污染工作区，需要翻原始数据去那里找。
- **`create-fix-branch.sh` 报"工作区有未提交改动"时，先看清楚那是什么。** 实测遇到过仓库根目录躺着一个
  302MB 的 `core.25013`——`strings core.* | head` 一看是 **google-chrome 崩溃留下的 core dump**
  （浏览器自动化的 profile 路径），跟本仓库毫无关系，而 `.gitignore` 只忽略了 `_build`/`bin`，不覆盖 `core.*`。
  确认来源与本仓库无关就删掉再重跑；**不要顺手把 `core.*` 加进 `.gitignore`**，那条改动会混进修复 PR。
- **本地 `make build` 要限制并行度。** 整个发行版编译默认按 CPU 数并行，容易把内存吃满
  （用户环境有内存上限约束）。实测 `GOFLAGS=-p=4 bash "$SKILL_DIR/scripts/build-verify.sh"`
  编译进程 RSS 峰值约 300MB，全程平稳。

## 步骤 1：漏洞检测

```bash
bash "$SKILL_DIR/scripts/resolve-input.sh" <run|镜像>   # Bash timeout 设 120000
bash "$SKILL_DIR/scripts/scan-image.sh"                 # Bash timeout 设 600000（服务端要先拉镜像）
```

`resolve-input.sh` 以**当前检出分支**作为修复基线。如果目标镜像是某个 PR 构建出来的、修复应该落在那个
PR 分支上，先检出该分支再调用本 skill。

**无论有没有漏洞，都要先把扫描摘要输出给用户**（每镜像漏洞数、SUMMARY 分类计数、修复目标表），
然后按 `RESULT:` 分支：

- **CLEAN**：无漏洞。**但 CLEAN 是本 skill 最容易搞错的结论，不能直接汇报**，
  先走完下面的「假阴性守卫」两步，全通过才能说"镜像干净"；
- **REPORT_ONLY**：剩余全是不修复项（os 级 / 无修复版本）。列明细并说明原因，结束；
- **FIX_NEEDED**：执行步骤 2～5。

**假阴性守卫**（只在 **Go 漏洞总数为 0** 时才需要走；
stdlib 条目和依赖条目出自同一个 gobinary 解析器，所以只要 stdlib 报出了漏洞，
就已经证明二进制被解析了，此时 `GO_MODULE=0` 是可信的，不用再对照）：
扫描 API 返回的 `{"os":[...],"lang":[...]}` 里**只装漏洞、不装包清单**，
所以 `{"os":[],"lang":[]}` 这种响应，"真干净"和"根本没扫到东西"长得一模一样，
「0 条」自己证明不了自己。镜像里又是一个 180MB 的 Go 二进制，报 0 条有两种可能，
逐一排除后才能下结论：

1. **扫描链路坏了**（`CONTROL:`，脚本自动查）——拿一个必定有漏洞的公共镜像走同一条链路对照，
   `SUSPECT` 说明服务或漏洞库异常，结果不可信。（镜像不存在这种情况不用担心，服务会返回
   `{"error": ... MANIFEST_UNKNOWN}`，脚本的 `has("os") and has("lang")` 校验拦得住，不会被当成 0 条。）
2. **解释得通吗**（**必须人工做，脚本代替不了**）——上一步只证明"链路是通的"，
   不证明"这个二进制被解析了"。要再拿证据说明这 0 条**为什么**成立，两个都不贵的办法：
   - **历史镜像对照**：扫一个同 Dockerfile、同基础镜像、但 collector 版本更老的本仓库镜像
     （用 `extract_run_image` 从早先的成功 run 取）。老镜像能扫出 Go 漏洞 → 证明这类镜像的
     gobinary 解析有效，那新镜像的 0 条就是真的；老镜像也是 0 条 → 高度可疑。
   - **源侧核对依赖版本**：从 module proxy 抓 `manifest.yaml` 里各组件的 go.mod，
     看老镜像里那些有漏洞的模块在新版本被抬到了什么版本（go.mod 含 `// indirect` 行，
     间接依赖也查得到；MVS 取最大值，所以直接依赖里的最高版本就是最终版本下界）：
     ```bash
     # 模块路径含大写字母时 proxy 要求转义成 !小写
     curl -sS "https://goproxy.cn/<escaped-module>/@v/<version>.mod"
     ```
     模块被整个移出依赖图（引用组件数 → 0）也是合理解释，尤其能解释那些**无修复版本**的 CVE
     为什么消失了——它们只要还在依赖图里就一定会被报出来。

   实测 2026-08：0.158.0 镜像 0 条，用 0.147.0 镜像对照扫出 40 条，逐条核对确认
   `apache/thrift` v0.22.0→v0.24.0 等全部抬过修复版本、`docker/docker` 和 `mongo-driver`
   被移出依赖图，这个 CLEAN 才站得住。

   环境限制（别在这上面浪费时间）：开发容器里**没有 docker/skopeo/crane**，
   `build-harbor.alauda.cn` 也**不允许匿名 pull**（拿得到 token 但 manifest 仍 401），
   所以"把镜像拉下来 `go version -m` 看一眼"这条路走不通，只能用上面两个间接办法。

## 步骤 2：修复

```bash
bash "$SKILL_DIR/scripts/create-fix-branch.sh"    # 输出 BRANCH= / BASE=
```

工作区不干净、或本地基线分支领先 origin 时脚本会终止（防止把无关改动混进 PR），按提示与用户确认。

然后按扫描输出的「修复目标」逐条应用（两类可以在一次调用里一起做）：

```bash
bash "$SKILL_DIR/scripts/apply-fix.sh" \
  --go 1.26.7 \
  --replace 'golang.org/x/net@v0.46.0#CVE-2026-1234,CVE-2026-5678'
```

`#` 后面的 CVE 列表会写成 manifest.yaml 里的行尾注释，以后能看出这条 replace 为什么存在。
输出 `GO_MINOR_CHANGED` 说明跨了 Go 次版本，要在最终报告里着重说明。

接着本地构建 + 落位校验。编译整个发行版通常几分钟到十几分钟，**必须后台运行**（`run_in_background: true`）：

```bash
bash "$SKILL_DIR/scripts/build-verify.sh"
```

- **BUILD_OK（0）**：构建通过且修复目标全部落位，提交进入步骤 3。
  两类修复各自独立 commit（禁止 amend）：
  - `fix: bump go to X.Y.Z for <CVE编号>`
  - `fix: pin vulnerable modules in manifest`
- **TARGET_UNMET（3）**：构建通过但有目标没落位——**这时候提 PR 也修不掉漏洞**。
  常见原因：replace 版本写低了、模块路径拼错、或该 CVE 实际来自另一个模块（扫描报的是被依赖的包，
  真正要钉的是它的上游）。分析清楚改完重跑本脚本，别急着提 PR。
- **BUILD_FAILED（2）**：脚本已附错误相关行与日志末尾。常见原因是 replace 的版本与其他模块 API
  不兼容、版本不存在、或新依赖要求更高的 Go。能明确解决就解决；拿不准就带着报错问用户，
  不要凭猜测连锁升级一堆模块。

## 步骤 3：创建 PR

先把 PR 正文写进 scratchpad 临时文件：扫描摘要（镜像、分类计数）+ 修复清单（每项：模块、版本变化、
覆盖的 CVE）+ 本地构建与落位校验结果 + 不修复项说明（os 级 / 无修复版本），
结尾一行 `🤖 Generated with [Claude Code](https://claude.com/claude-code)`。然后：

```bash
bash "$SKILL_DIR/scripts/create-pr.sh" <正文文件>    # 输出 PR_NUMBER= / PR_URL=
```

幂等：分支已有 open PR 时复用，回归轮 push 新 commit 后重跑即可。

## 步骤 4：监控流水线

双平台镜像构建通常 10～40 分钟，**必须后台运行**（`run_in_background: true`）：

```bash
bash "$SKILL_DIR/scripts/watch-pr.sh"
```

等待期间要看进度就 Read 后台任务的输出文件；不要前台 `sleep` 轮询。按退出结果处理：

- **PIPELINE_SUCCESS（0）**：脚本已收集好新镜像并把轮次 +1，进入步骤 5；
- **PIPELINE_FAILED（2）**：脚本已附失败概览与日志摘要。判断是本次修复引入的
  （replace 冲突、Go 版本写错、基础镜像 tag 不存在）还是环境问题（runner 离线、registry 登录、代理）。
  属于本次修复引入的就修 → 新 commit → `git push origin HEAD` → 重跑本脚本；
  环境问题或方案拿不准就停下来把分析交给用户，不要盲改重推；
- **PIPELINE_TIMEOUT（3）**：告知用户流水线仍在运行并附 run 链接，稍后可重跑本脚本继续等；
- **PIPELINE_NOT_FOUND（4）**：按脚本给的三个方向排查后如实告知。

## 步骤 5：回归扫描与迭代

```bash
bash "$SKILL_DIR/scripts/scan-image.sh"    # ROUND 已 +1，自动扫 PR 构建的新镜像
```

- **CLEAN / REPORT_ONLY**：修复完成。先用 `gh pr comment --repo alauda-mesh/alauda-opentelemetry-collector`
  把回归扫描结论回填到 PR 供 review 参考，再进入最终汇报；
- **FIX_NEEDED**：先分析**为什么还有漏洞**（上轮目标版本本身仍带 CVE？replace 没生效？
  新版本引入了新漏洞？），再回到步骤 2 继续修——不新建分支，在同一分支追加 commit →
  `create-pr.sh` push → 后台 `watch-pr.sh` → 再扫描。

**最多 3 轮修复**。到限仍未清零就停止，如实汇报剩余漏洞、已尝试的措施和失败原因。

## 最终汇报

用清晰的列表汇报，这是用户验收的依据：

1. **输入与扫描清单**：run / 镜像，解析出的待扫镜像；
2. **首轮扫描摘要**：总数与分类计数；若结果是 0 条，必须一并给出假阴性守卫两步的证据
   （`CONTROL` + 你用来解释"为什么是 0"的对照/源侧核对结论），
   否则"镜像干净"这个结论没有依据；
3. **修复清单**：每项写清模块/标准库、版本变化、覆盖的 CVE、对应 commit；
4. **本地验证**：构建结果 + 落位校验（产物里实际版本 vs 目标版本）；
5. **PR 与流水线**：PR 链接、流水线结果，成功则给出新镜像地址；
6. **回归扫描结论**：轮次与最终扫描摘要；
7. **不修复项**：os 级漏洞明细、无修复版本或修不掉的项及原因，注明不在修复范围；
8. 若 Go 跨了次版本（如 1.26.x → 1.27.x），**着重强调**该变更及原因。

不要自行 merge PR，等用户 review。

---
name: sync-upstream
description: 把 alauda-mesh/alauda-opentelemetry-collector 升级到指定的上游 OpenTelemetry Collector tag（如 v0.158.0）。完成四件事：基于 main 建分支并升级 Makefile/manifest.yaml 的版本后做本地构建校验、追踪 OCP（Red Hat build of OpenTelemetry）近期更新并给出跟进建议、对比两侧 manifest 的 OTel 组件差异并给出跟进建议、创建 PR 并监控构建流水线（失败时分析原因并尝试修复）。仅限用户显式通过 /sync-upstream 调用。
argument-hint: "[上游 tag]，例如: v0.158.0"
disable-model-invocation: true
---

# 升级 OpenTelemetry Collector 版本

把本仓库升级到 <https://github.com/open-telemetry/opentelemetry-collector-releases> 的指定 tag，
并顺带跟进 OCP 的更新内容，最后建 PR 并盯完流水线。
下文的 `$SKILL_DIR` 指本 skill 的根目录（即调用时提示的 Base directory）。

## 参数

- 上游 tag：`$0`（形如 `v0.158.0`）

为空时先列出上游最近的正式 tag，再用 AskUserQuestion 让用户选（推荐最新的那个），不要自行猜测：

```bash
gh api "repos/open-telemetry/opentelemetry-collector-releases/tags?per_page=100" -q '.[].name' | grep -v nightly | head -6
```

## 背景知识

- 本仓库是 Alauda 自己的 OTel Collector 发行版，**没有 Go 源码**：`Makefile` 的 `OCB_VERSION` 决定用哪个版本的
  ocb 和镜像 tag，`manifest.yaml` 是 ocb 的组件清单，加上 `Dockerfile`、`configs/otelcol.yaml`
  和一条流水线 `.github/workflows/alauda-build-otelcol.yaml`。所以"升级版本"本质就是改这两个文件的版本号。
- `manifest.yaml` 是从 **OCP**（Red Hat build of OpenTelemetry，仓库 `os-observability/redhat-opentelemetry-collector`）
  的同名文件裁剪来的，两边结构一一对应。ACP 不做 AWS/GCP 云厂商相关组件；OCP 里 RPM spec、SELinux、packit
  那一套面向 RHEL 主机部署的东西，对交付容器镜像的 ACP 完全不适用。
- 组件模块的确切版本以上游 `opentelemetry-collector-releases` 对应 tag 的
  `distributions/otelcol-contrib/manifest.yaml` 为准。尤其 `confmap/provider/*` 走的是 `v1.x`
  稳定版本线（0.147.0 对应 v1.53.0、0.158.0 对应 v1.64.0），**不能按 `v0.x` 的规律去猜**，
  步骤 1 的脚本已经帮你查好了。
- 流水线的 `paths` 过滤只含 `Dockerfile` / `manifest.yaml` / 该 workflow 自身，**不含 Makefile**。
  正常的版本升级 PR 一定改了 manifest.yaml，所以会触发；但如果某次只改了 Makefile，PR 是不会构建的。
- 本地通常没有 docker，镜像构建只能靠步骤 4 的流水线验证。步骤 1 的 `make build` 验证的是 ocb
  组件解析与 Go 编译，这已经能拦住绝大多数版本/组件问题。
- OCP 仓库把 `_build/`（ocb 生成的 go.mod/main.go 等）和 `configschemas/` 的生成物也提交进了仓库，
  一次提交能带 200 多个文件。这些是他们的构建产物，不是需要 ACP 跟进的内容，步骤 2 的脚本已把它们折叠。
- 各脚本的中间产物（上游 manifest 缓存、commit JSON、构建日志、步骤间状态）都放在 `.git/otel-sync/` 下，
  不会污染工作区，需要翻原始数据时去那里找。
- 全程禁止 `git commit --amend`，一律创建新 commit，message 里不要带 `Co-Authored-By`。
  步骤 4 之前不要 push、不要建 PR。

## 步骤 1：升级版本并本地构建

```bash
bash "$SKILL_DIR/scripts/bump-version.sh" <上游tag>
```

脚本会：校验 tag 在上游确实存在 → 检查工作区干净 → 基于 `origin/main` 创建 `sync/<tag>` 分支 →
拉上游 `otelcol-contrib/manifest.yaml` 建立"模块 → 版本"映射 → 改写 `manifest.yaml` 每一行 `gomod`
的版本、`dist.version`，以及 Makefile 的 `OCB_VERSION`。**只改版本号，不增删组件**（组件的事留到步骤
2、3），也**不自动 commit**，方便你先看 diff。

看输出里的四类判定：

- **MAP**：版本取自上游 contrib manifest，可信，不用管；
- **FALLBACK**：上游 contrib 没收录该模块（目前只有 `memorylimiterextension` 属于这种），按发布节奏推导，通常正确；
- **SKIP**：该模块的版本不跟随 collector 发布节奏（比如将来引入 `go.opentelemetry.io/obi v0.10.0` 这类），脚本原样保留；
- **UNPARSED**：行形态不认识，脚本没敢动。

SKIP 和 UNPARSED **必须逐条判断**是否需要单独升级——这正是脚本不敢替你决定的部分。拿不准就停下来问用户。

失败（退出码 1）通常是前置条件问题（工作区不干净、同步分支已存在、tag 不存在）。把脚本报错原样告知用户
并询问如何处理，不要擅自 stash、删分支或换 tag。

然后做本地构建校验。编译整个发行版通常要几分钟到十几分钟，**必须用后台方式运行**（Bash 工具的
`run_in_background: true`）：

```bash
bash "$SKILL_DIR/scripts/build.sh"
```

- **BUILD_SUCCESS（0）**：还要看两项检查。
  - **Go 版本检查**：新版本 collector 抬高 `go` 指令、而流水线的 `BUILD_BASE_IMAGE_VERSION` 没跟上时，
    本地能编过但 CI 必然失败——这类问题只在 CI 暴露，白白浪费一轮流水线。出现该 WARN 就用 Edit 把
    workflow 的 `BUILD_BASE_IMAGE_VERSION`（以及 Dockerfile 里同名 ARG 的默认值）提到要求版本以上。
  - **组件完整性检查**：以 manifest 的模块是否都进了 ocb 生成的 `_build/*.go` 为准。这一项报 WARN
    才是真的丢了组件。**不要拿 `otelcol components` 的数量去对 manifest 的数量**——那个命令本身会漏列
    （实测 0.147.0 漏了 otlp/otlphttp exporter 和 k8sattributes processor，但它们确实编译进去了），
    按它判断会每次都误报组件缺失。
- **BUILD_FAILED（2）**：脚本已附错误相关行和日志末尾。常见原因是某个组件在新版本被重命名或移除、
  模块版本不存在、或 Go 版本过低。分析后改 `manifest.yaml` 再重跑；拿不准就停下来问用户。

构建通过后提交：`git add -A && git commit -m "chore: upgrade to version <X.Y.Z>"`（沿用仓库历史的 commit 风格）。

## 步骤 2：追踪 OCP 更新内容

```bash
bash "$SKILL_DIR/scripts/ocp-changes.sh"
```

脚本自动算时间窗（ACP 最新 release 的发布日期回退 1 个月 → OCP main 最新提交日期），列出窗口内 OCP main
的每一条提交：日期、SHA、标题、PR 链接、改动文件，以及一个初判分类。需要自定义窗口时加
`--since YYYY-MM-DD` / `--until YYYY-MM-DD`。

分类只是把明显不需要人判断的提交先滤掉，**结论仍然要你自己下**：

- `VERSION_BUMP` / `DEPS`：ACP 通过步骤 1 已经自然跟上，不用单独跟进；
- `RHEL_ONLY`（`.spec.in`、SELinux `.te`、packit、chainsaw 等）：ACP 交付容器镜像，不适用；
- `DOC`：一般不跟进，除非文档描述的是我们也该有的能力；
- `MANIFEST_COMPONENT` / `CONFIG` / `OTHER`：需要看 PR 内容判断。要看具体 diff 时读脚本缓存的 commit
  JSON，或用 `gh api repos/os-observability/redhat-opentelemetry-collector/commits/<sha> -q '.files[] | .filename, .patch'`。

判断"ACP 是否已包含该功能"时，对照本仓库的 `manifest.yaml`、`Dockerfile`、`configs/otelcol.yaml` 和 workflow。

然后输出**编号报告**给用户 review：

```markdown
| # | OCP 变更 | 分类 | ACP 现状 | 适用性 | 建议 |
|---|---------|------|---------|-------|------|
| 1 | Add OBI receiver (#146) | MANIFEST_COMPONENT | 未包含 | ... | 建议跟进 / 不建议 |
```

表格下面附一行：
`请回复要跟进的编号（如 1,3）；全部跟进回 all，都不跟进回 none；也可以直接说你的想法。`

**然后停下来等用户回复**，不要自作主张先改。这一步是用户 review 的入口，抢跑会让整件事失去意义。

拿到回复后按选中项修改（多数是往 `manifest.yaml` 加组件，也可能改 `Dockerfile` / `configs/otelcol.yaml` /
workflow），改完重跑 `build.sh`（后台），通过后单独提交一个 commit（如 `chore: follow up OCP changes`）。
用户回 none 就跳过修改，直接进步骤 3。

## 步骤 3：对比 manifest 组件差异

必须在步骤 2 的跟进改动落地之后再跑，否则差异清单里会混进已经处理过的项：

```bash
bash "$SKILL_DIR/scripts/diff-components.sh"
```

脚本输出三部分：**仅 OCP 有 / ACP 缺少**（已编号，并给出可直接粘贴进 manifest.yaml 的 `- gomod:` 行）、
**仅 ACP 有**、**共有模块的版本差异**（两侧 collector 版本一致时才有意义，正常应为空；非空说明有模块版本
脱轨了，要查清楚）。

逐条给出跟进建议时考虑：ACP 的使用场景（服务网格 / 可观测性，不涉及 AWS/GCP 托管服务）、组件的稳定性等级、
以及引入后对镜像体积和依赖面的影响。步骤 2 已经决策过的条目要标注"已在步骤 2 处理"，不要让用户重复 review。

带 **⚠** 标记的条目要特别当心：那说明该模块在 OCP 侧还配了 `import:` 续行或 `replaces:` 重定向
（例如 `go.opentelemetry.io/obi` 被 replace 到本地 clone 的源码目录），照抄一行 `gomod` 必然构建失败。
这类要么连带把 OCP 的完整配置搬过来（包括 Makefile 里拉源码的步骤），要么在报告里如实说明成本、建议不跟进。

报告格式同步骤 2：

```markdown
| # | 组件 | 段落 | 状态 | 建议 | 理由 |
|---|-----|------|------|------|------|
```

附上同样的一行回复提示，**停下来等用户回复**。拿到回复后修改 `manifest.yaml`（注意加到对应段落里，
保持与 OCP 一致的相对顺序，便于以后对比）→ 重跑 `build.sh`（后台）→ 单独提交一个 commit
（如 `chore: add <组件> to manifest`）。

## 步骤 4：创建 PR 并监控流水线

先把 PR 描述写进 scratchpad 下的临时文件（如 `pr-body.md`）：内容取最终汇报的精简版（版本变更、
OCP 跟进结论、组件变更、本地构建结果），结尾加一行
`🤖 Generated with [Claude Code](https://claude.com/claude-code)`。然后：

```bash
bash "$SKILL_DIR/scripts/create-pr.sh" <PR正文文件>
```

脚本会 push 同步分支并创建 PR（分支已有 open PR 时幂等复用），输出 `PR_NUMBER=` 与 `PR_URL=`。
若报 gh 未认证，提示用户执行 `! gh auth login` 后重试。

接着监控流水线。self-hosted runner 上的双平台镜像构建通常需要 10～40 分钟，
**必须用后台方式运行**（`run_in_background: true`），完成后会收到通知：

```bash
bash "$SKILL_DIR/scripts/watch-pipeline.sh"
```

按退出结果处理：

- **PIPELINE_SUCCESS（0）**：把输出里的构建镜像名加入最终汇报；
- **PIPELINE_FAILED（2）**：脚本已附失败概览与日志摘要。定位失败 step，判断是本次升级引入的
  （新版本组件不兼容、Go 版本过低、manifest 组件写错）还是环境问题（runner 离线、registry 登录、代理、
  基础镜像拉取）。需要更多日志时用 `gh run view <run-id> --repo alauda-mesh/alauda-opentelemetry-collector --log-failed`。
  **属于本次升级引入的问题最多尝试修复 2 次**：修复 → 新 commit → `git push origin HEAD` → 重新后台运行
  watch-pipeline.sh。两次仍失败，或原因是环境问题、或修复方案拿不准，就停下来把分析结论交给用户，不要继续盲改；
- **PIPELINE_TIMEOUT（3）**：告知用户流水线仍在运行并附 run 链接，之后可用 `gh run view <run-id>` 查看；
- **PIPELINE_NOT_FOUND（4）**：按脚本给的三个排查方向核对后如实告知用户。

不要自行 merge PR，也不要打 release tag —— 那是用户 review 之后的事（见 README 的发布章节）。

## 最终汇报

用清晰的列表汇报下面这些，这是用户验收的依据：

1. **分支与版本**：分支名、`OLD → NEW` 版本、providers 的 `v1.x` 版本变化、SKIP/UNPARSED 项的处理结论；
2. **本地构建**：BUILD_SUCCESS/FAILED、组件数量、Go 版本检查结论（有没有改 workflow 的 `BUILD_BASE_IMAGE_VERSION`）；
3. **OCP 更新跟进**：时间窗、逐条结论（跟进了什么 / 为什么跳过）；
4. **组件差异跟进**：新增/保留了哪些组件及理由；
5. **PR**：链接与提交列表；
6. **流水线**：结果，成功则给出镜像名
   `build-harbor.alauda.cn/asm/opentelemetry-collector:<版本>-pr.<PR号>.<run号>`，失败则给出原因分析与已尝试的修复。

到此流程结束，等用户 review 与合并。

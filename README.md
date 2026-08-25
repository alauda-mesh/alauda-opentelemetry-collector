# Alauda’s OpenTelemetry Collector Distribution

## Update collector version

### 通过 skill 更新（推荐）

在本仓库根目录执行，参数是目标上游 tag：

```
/sync-upstream v0.158.0
```

skill 位于 [.claude/skills/sync-upstream](./.claude/skills/sync-upstream)，依次完成四步：

1. **升级版本**：基于 `main` 创建 `sync/<tag>` 分支，把 `Makefile` 的 `OCB_VERSION` 和 `manifest.yaml`
   里全部模块的版本升到目标 tag，然后 `make build` 做本地构建校验。模块版本取自上游对应 tag 的
   `otelcol-contrib/manifest.yaml`，不靠推测——`confmap/provider/*` 走的是独立的 `v1.x` 版本线，手改很容易搞错。
2. **追踪 OCP 更新**：列出 [Red Hat build of OpenTelemetry](https://github.com/os-observability/redhat-opentelemetry-collector)
   在「上一个 ACP release 日期回退一个月」至今的全部提交，逐条判断 ACP 是否适用，输出带编号的建议表。
3. **对比组件差异**：对比两侧 `manifest.yaml` 的 OTel 组件列表，输出带编号的差异说明与跟进建议。
4. **创建 PR 并监控流水线**：用 `gh` 建 PR，盯完
   [Alauda Build OpenTelemetry Collector](./.github/workflows/alauda-build-otelcol.yaml) 流水线；
   失败会分析原因并最多尝试修复 2 次，最后给出完整报告。

第 2、3 步都会停下来等你回复要跟进的编号，不会自行增删组件；PR 也不会自动合并，仍需你 review。

前置条件：`gh` 已登录（`gh auth login`）、本地有 Go 工具链。

### 手动更新

1. 修改 [Makefile](./Makefile) 中的 `OCB_VERSION`，指定目标上游版本。
2. 修改 [manifest.yaml](./manifest.yaml)，指定目标上游版本，以及本次产品发布所需的组件集合。
   参考：[opentelemetry-collector-releases/distributions/otelcol-contrib/manifest.yaml](https://github.com/open-telemetry/opentelemetry-collector-releases/blob/main/distributions/otelcol-contrib/manifest.yaml)
3. 执行 `make build` 做一次本地构建测试。

## 漏洞修复

修复流水线构建出的 otelcol 镜像漏洞。在本仓库根目录执行，参数是构建流水线的 run ID（或 run URL），
也可以直接给镜像地址：

```
/fix-image-vulns 31468229342
/fix-image-vulns build-harbor.alauda.cn/asm/opentelemetry-collector:0.158.0-pr.5.15
```

skill 位于 [.claude/skills/fix-image-vulns](./.claude/skills/fix-image-vulns)，流程是：
扫描镜像（内网服务）→ 按责任分类 → 修复 → 本地 `make build` 并校验修复真的落到产物上 →
建 PR 并盯流水线 → 回归扫描，还有漏洞就再修，最多 3 轮。

两类漏洞的修法：

| 类别 | 修复手段 |
| --- | --- |
| Go 标准库 | 升 [alauda-build-otelcol.yaml](./.github/workflows/alauda-build-otelcol.yaml) 的 `BUILD_BASE_IMAGE_VERSION` |
| Go 依赖库 | 在 [manifest.yaml](./manifest.yaml) 的 `replaces:` 段把模块钉到修复版本 |
| os 级 | **不修**，只在报告里如实列出（归基础镜像维护方） |

修复基线是**当前检出分支**，所以要把修复提到某个 PR 分支上时，先检出那个分支再调用。
PR 不会自动合并，仍需你 review。

前置条件：`gh` 已登录（`gh auth login`）、本地有 Go 工具链、能访问内网扫描服务。

## Release

After creating a new Release with a tag in the format `vx.y.z-rn` (for example, `v0.145.0-r0`), the image build action will be triggered automatically.

## Local build

```bash
make build
# Check available components in this collector distribution
./_build/otelcol components
```

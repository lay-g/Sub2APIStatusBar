# 收敛 CodexProxy 的刷新请求量并修正今日/累计口径

本 ExecPlan 是一份持续更新的文档。实施过程中必须始终维护“进度”、“意外与发现”、“决策记录”和“成果与复盘”四个章节。

## 目标与整体说明

这个改动完成后，使用 codex-proxy-rs 账号的用户在状态栏面板上会看到三件可观察的变化。

第一，“Today Cost”与它下方的“Total”不再显示同一个数字。今日是自本地零点起的花费，累计是自本月 1 日零点起的花费。

第二，“Avg Response”不再恒为 `0 ms`，“Performance”一栏的 TPM 不再恒为 `0`。这两个数字目前对 codexProxy 账号永远是零值，属于明显的功能缺失。

第三，上述两项改善的同时，每轮刷新发出的 HTTP 请求数从 9 个降到 7 个。这是本计划的硬约束：绝不能为了补数据而增加请求量。

用户已明确否决“分页拉取 `/api/user/usage/records` 做客户端聚合”这一整类方案，原因是请求量不可接受，详见“决策记录”。因此本计划只使用服务端已经聚合好的端点，并接受由此带来的能力缺口，在“接口与依赖”中逐条记录哪些指标因此拿不到。

## 进度

- [x] (2026-09-17 09:20Z) 里程碑 1：新增 `CodexProxyRequestCache` actor（缓存 Task 而非结果值），`CodexProxyDataProvider` 全量改走缓存，请求数从 9 降到 6。新增 `CodexProxyRequestBudgetTests` 以桩 `URLProtocol` 计数验证。
- [x] (2026-09-17 09:20Z) 里程碑 2：`CodexProxyDate` 新增 `todayWindow` / `monthToDateWindow`，`fetchDashboardStats` 改为两次窗口不同的 summary，`toDashboardStats` 签名改为 `todaySummary` / `monthSummary`，请求数升到 7。补窗口与分离单元测试。
- [x] (2026-09-17 09:20Z) 里程碑 3：`CodexProxyCostSection` 补解码 `tokensPerRequest`，`CodexProxyUsageOverview` 加 `tokensPerRequest` 计算属性（服务端值优先、总 token/总请求兜底），`realtimeWindow` 由 actor 惰性固定以保证缓存命中，`averageDurationMs` 与 `tpm` 填入。overview 仍只发 2 次。
- [x] (2026-09-17 09:20Z) 里程碑 4：`CodexProxyUsageOverview` 与 `toModelUsageSummaries` 注释记录储备项与放弃项，指向本计划文件。未新增 md 文档。
- [x] (2026-09-17 09:20Z) 自动化验证：`swift build` 无警告，`swift test` 89 项全过，含预算断言 `counter.total == 7`。
- [x] 服务端冒烟验证：登录及各聚合端点调用成功，确认服务端接受今日与当月窗口。账号、服务地址和用量记录不保留。
- [x] (2026-09-17 11:00Z) 里程碑 5：`CodexProxyDataProvider` 与 `CodexProxyRequestCache` 注入 `@Sendable () -> Date` 时钟，`fetchDashboardStats` 共用一个 `now()` 使两窗口 end 一致。预算测试改注入固定日期，并把每月 1 日「summary 合并为 1 次、总数 6」固化为独立用例。
- [x] (2026-09-17 11:22Z) 里程碑 6 已全部回退。用户确认最终目标是「只加 codexProxy 支持，UI 展示内容不变，支持不了的数据直接放弃」，因此新增字段与新增 tile 均不符合要求。`Models.swift` 与 `MonitorPanel.swift` 已回到原样，四项储备数据正式放弃。
- [x] 面板肉眼验证：用户提供的最新截图确认今日与累计数据分离，Avg Response 与 TPM 均显示非零值。仅记录验收结论，不保留截图及具体用量。

## 意外与发现

- 观察：`averageDurationMs` 与 `tpm` 不只是面板上的两个数字，`averageDurationMs` 还驱动一条延迟告警洞察。修好它会让 codexProxy 账号第一次开始触发该告警。
  证据：`Sources/Sub2APIStatusCore/UsageInsights.swift:305` 判断 `stats.averageDurationMs >= thresholds.latencyWarningMs`，而 `Sources/Sub2APIStatusCore/CodexProxyAdapters.swift:96` 目前写死 `averageDurationMs: 0`，该分支对 codexProxy 恒不成立。

- 观察：原先判断“请求级错误码分布必须靠 records 聚合”是错的。`/records/summary` 和 `/insights/overview` 的 `attempts` 段里已经有按错因拆分的计数。
  证据：`Tests/Sub2APIStatusCoreTests/CodexProxyTests.swift:149-152` 的测试固件包含 `rateLimitedCount`、`authFailureCount`、`provider5xxCount` 字段。但 `CodexProxyUsageOverview` 的 `CodingKeys` 只声明了 `granularity`、`health`、`performance`、`cost`（`Sources/Sub2APIStatusCore/CodexProxyModels.swift:661-666`），`attempts` 段被整段丢弃。

- 观察：`/insights/overview` 还免费给出了按 provider 的用量拆分，同样未被解码。
  证据：同一测试固件 `Tests/Sub2APIStatusCoreTests/CodexProxyTests.swift:192` 含 `providers` 数组。

- 观察：`/usage/records` 的单条记录里没有 `status` 或 `statusCode` 字段，`CodexProxyUsageRecord.status` 的默认值 `"success"` 意味着所有记录都会被当成成功。
  证据：测试固件 `Tests/Sub2APIStatusCoreTests/CodexProxyTests.swift:296-309` 没有这两个键；`Sources/Sub2APIStatusCore/CodexProxyModels.swift:437` 用 `?? "success"` 兜底。这进一步说明 records 不适合用来统计失败情况。

- 观察：`DashboardStats` 里没有 reasoning token 和缓存节省的字段，这两项数据虽然已经拿到手，却无处安放。
  证据：`Sources/Sub2APIStatusCore/Models.swift:144-173` 的字段清单中不存在对应项；而 `CodexProxyUsageSummary.reasoningTokens`（`CodexProxyModels.swift:560`）与 `CodexProxyCostSection.savings`（`CodexProxyModels.swift:831`）都已实现且无任何调用方。

- 观察：`totalCost` 与 `todayCost`（不带 `actual` 的那两个）在整个 UI 中没有任何读取方，界面一律读 `todayActualCost` / `totalActualCost`。
  证据：对 `Sources/` 全量检索 `totalActualCost|todayActualCost|standardCost` 的结果中，`MonitorPanel.swift:190`、`Sub2APIStatusBarApp.swift:79`、`UsageReport.swift:25,32`、`Models.swift:1279-1294` 等展示位全部使用 `*ActualCost`，无一处使用 `totalCost` 或 `todayCost`。

- 接口约束：diagnostics 的 `attemptCount` 可能小于 `requestCount`，二者不能简单理解为重试倍数关系。请求数一律取 `requestCount`。

- 空闲窗口处理：overview 的延迟分位允许为 JSON `null`。解码器用 `decodeIfPresent(...) ?? 0` 安全降级；非零指标的人工验收需在有实时流量时进行。

## 决策记录

- 决策：不实现任何基于 `/api/user/usage/records` 分页的客户端聚合。
  理由：该端点 `pageSize` 上限为 100，覆盖 7 天窗口需要 `总记录数 / 100` 次请求，且每轮刷新都要重来。默认刷新间隔为 15 秒（`Sources/Sub2APIStatusCore/AppConfig.swift:399`），一周 1000 次调用就意味着额外 40 请求/分钟。用户明确以“不想造成太多的请求”为由否决此方案。
  日期/作者：2026-09-17 / Lay 决策，助手记录。

- 决策：“累计”口径定义为当月 1 日零点至当前，而非账号创建至今。界面文案与提示一律不改。
  理由：用户明确要求“累计请求可以用当月的，不用展示从开始到现在的数据”，并要求“不需要调整展示方式以及提示内容”。
  日期/作者：2026-09-17 / Lay 决策，助手记录。

- 决策：接受 `Sources/Sub2APIStatusCore/UsageReport.swift:32` 中“Lifetime Spend”这一文案与当月口径不符的事实，不修改文案。
  理由：上一条决策明确禁止改动文案。此处仅作记录，供日后若放开文案改动时一并处理。
  日期/作者：2026-09-17 / 助手记录，依据用户上述指示。

- 决策：`averageDurationMs` 填入 1 小时窗口 overview 的 `performance.latencyP50Ms`，而不是解析 `/records/summary` 顶层的 `averageLatencyMs`。
  理由：`averageLatencyMs` 是给网页渲染用的展示字符串，形如 `"13.69 s"`，解析它需要自行判别 `s` 与 `ms` 单位，容易在服务端换单位时静默算错 1000 倍。`latencyP50Ms` 是干净的数值。代价是它是 P50 而非算术平均，且窗口是最近 1 小时而非今日；换取的好处是复用里程碑 1 的缓存，零额外请求。若日后要求严格的“今日平均”，需为今日窗口再发一次 overview，即 +1 请求。
  日期/作者：2026-09-17 / 助手。

- 决策：不把 `overview.cost.standardCost` 映射进 `DashboardStats.totalCost` / `todayCost` 来间接表达缓存节省。
  理由：`/records/summary` 不含 `standardCost`，只有 overview 有；而 overview 的窗口与 summary 的今日/当月窗口不一致，混用会得出自相矛盾的数字。要口径一致就得为今日窗口额外发一次 overview，违反请求预算约束。且这两个字段目前无 UI 读取方，映射了也看不见。
  日期/作者：2026-09-17 / 助手。

- 决策：不为 reasoning token、缓存节省、attempts 错因拆分、provider 拆分新增 `DashboardStats` 字段或 UI 展示位。
  理由：这四项数据都已经在手（或只需补几行解码），但都没有展示位。新增字段会改动 Sub2API 与 codexProxy 共用的 `DashboardStats`，并需要配套 UI，超出本次“收敛请求量 + 修正口径”的范围。本计划把它们记录为可随时启用的储备项。
  日期/作者：2026-09-17 / 助手。

- 决策：请求合并的作用域是 `CodexProxyDataProvider` 实例，不引入全局缓存或 TTL。
  理由：`Sources/Sub2APIStatusBar/MonitorViewModel.swift:69` 在每轮刷新开始时新建 provider，401 重试时（同文件第 75 行）也会再建一个新的。因此“实例生命周期”天然等于“一轮刷新”，无需时间戳判过期，也不会让上一轮的失败或陈旧数据泄漏到下一轮。这同时满足项目既有偏好：不引入新的依赖组件。
  日期/作者：2026-09-17 / 助手。

- 决策：推翻此前“不为储备项新增 `DashboardStats` 字段”的决定，但只对窗口一致的两项执行。
  理由：用户 2026-09-17 明确要求启用储备数据项。经核查，`attempts` 错因拆分与 reasoning token 都来自**已在调用的今日/当月 summary**，窗口与 `today*` / `total*` 字段完全一致，因此能直接放进 `DashboardStats` 而不产生口径矛盾，也不增加请求。
  日期/作者：2026-09-17 / Lay 授权，助手设计。**此决策已于同日作废，见下条。**

- 决策（最终，覆盖前两条）：本次工作的范围是“只把 codexProxy 能对上的数据填进**现有**字段”。不新增任何模型字段、不新增任何 UI 展示位，对不上的数据直接放弃。
  理由：用户原话“ui已经展示内容不需要变化，最终目的知识加入codexProxy支持，支持不了的数据就直接放弃即可”。这是对整个任务目标的定性约束，优先级高于“把能拿到的数据都用上”的直觉。
  影响：里程碑 6 全部回退——`RequestFailureBreakdown`、`DashboardStats` 的四个新字段、`CodexProxyAttemptCounts` 的三个错因字段解码、面板两个新 tile 及其辅助方法、两个对应测试，全部删除。`Sources/Sub2APIStatusCore/Models.swift` 与 `Sources/Sub2APIStatusBar/MonitorPanel.swift` 恢复到本次会话前的状态。原计划“不修改 `Models.swift`”的边界重新生效。
  正式放弃的四项：`attempts` 错因拆分、`providers` 拆分、全局 reasoning token、`cacheSavings` 与标准价。它们的数据都能免费拿到，唯一原因是没有对应的现有展示位。
  日期/作者：2026-09-17 / Lay 决策，助手执行。

## 成果与复盘

五个里程碑已实现，`swift build` 无警告、`swift test` 90 项全过。里程碑 6 曾短暂启用两项储备数据，后应用户定性约束全部回退，因此最终落地的是 1–5。

请求数按计划从 9 收敛到 7，由 `CodexProxyRequestBudgetTests` 用桩 `URLProtocol` 计数守护：`/api/user/profile` 1 次、`/api/user/request-usage` 1 次、`/records/summary` 2 次、`/insights/overview` 2 次、`/insights/diagnostics` 1 次，合计 7。该测试以“全部 fetch 并发发起”的最坏情形运行，证明了 actor 缓存 Task 的去重在并发到达时确实生效。里程碑 5 之后该测试注入固定时钟，不再随日历抖动，每月 1 日的合并行为另有独立用例覆盖。

服务端冒烟验证确认接受当月时间窗口，未出现 `40001` 参数错误。此处仅保留兼容性结论，不保留账号与响应数据。

`Sources/Sub2APIStatusCore/Models.swift` 与 `Sources/Sub2APIStatusBar/MonitorPanel.swift` 恢复到本次会话前的状态，UI 展示内容完全不变。

实施中偏离计划的三点：一是 `tokensPerRequest` 兜底逻辑最初被错误地放在 `CodexProxyCostSection`（该结构无请求数，分母无意义），改回放在 `CodexProxyUsageOverview` 用 `health.totalRequests` 计算；二是测试辅助 `makeSummary` 无法用成员初始化器构造（相关结构仅有 `init(from:)`），改为解码 JSON；三是预算测试文件因两个用例共用静态计数器，改为 `@Suite(.serialized)` 并让计数器可重置，否则并行执行会互相干扰。

面板肉眼验证已完成：用户提供的最新截图确认今日与累计数据分离，Avg Response 与 TPM 均显示非零值。本计划的人工验收项已闭环，不保留截图及具体用量。

## 背景与定位

### 这个项目是什么

Sub2APIStatusBar 是一个 macOS 菜单栏应用，用 Swift Package Manager 构建（`Package.swift`，swift-tools-version 6.1，因此默认启用 Swift 6 严格并发检查）。它包含两个 target：`Sub2APIStatusCore` 是可测试的核心库，`Sub2APIStatusBar` 是 SwiftUI 可执行程序。

应用支持两个后端 provider，由 `AppConfig.provider` 选择：`sub2api` 和 `codexProxy`。本计划只涉及后者。

### codex-proxy-rs 与本应用的关系

codexProxy 指的是 codex-proxy-rs 这个 AI API 代理服务，具体是 `adalinkon` 这个 fork —— 官方 `zyycn` 版本只有 admin 与 client-key 两种角色，没有普通用户系统，而本应用对接的是 fork 才有的“普通用户”角色，走 `/api/user/*` 这批端点。

认证方式是会话 Cookie：`POST /api/admin/auth/login` 之后从 `Set-Cookie` 里取 `cpr_admin_session`，响应体里没有 token。会话 24 小时过期且没有 refresh token，所以登录密码被明文存进 `config.json` 以便静默重新登录。

所有响应都包着一层信封 `{"code":200,"message":"OK","data":...}`，成功码是 200（不是 0）。字段一律 camelCase。这些已由 `CodexProxyEnvelope`（`Sources/Sub2APIStatusCore/CodexProxyModels.swift:48`）处理。

### 数据是怎么流到界面上的

`DataProvider` 协议（`Sources/Sub2APIStatusCore/DataProvider.swift:4-25`）按“界面需要的数据块”拆成 7 个方法：`fetchCurrentUser`、`fetchSubscriptionSummary`、`fetchDashboardStats`、`fetchUsageTrend`、`fetchModelUsage`、`fetchRealtimeMetrics`、`fetchAccountHealth`。

`MonitorViewModel.userSnapshot`（`Sources/Sub2APIStatusBar/MonitorViewModel.swift:86-116`）用 `async let` 并发调用全部 7 个方法，把结果组装成一个 `MonitorSnapshot` 交给界面。

`CodexProxyDataProvider`（`Sources/Sub2APIStatusCore/DataProvider.swift:70-153`）把每个方法翻译成一到多个 codex-proxy-rs 的 HTTP 调用，再经 `CodexProxyAdapters`（`Sources/Sub2APIStatusCore/CodexProxyAdapters.swift`）把 codexProxy 的模型转成 `Models.swift` 里那套 provider 无关的统一模型。

问题就出在这个“按数据块拆分”的协议上：`fetchCurrentUser`、`fetchSubscriptionSummary`、`fetchDashboardStats` 三个方法各自独立地调用了一次 `/api/user/profile`，它们之间不知道彼此的存在。

### 当前每轮刷新的 9 个请求

逐个方法数清楚（这是本计划的基线，实施前应先用里程碑 1 的测试复现这个 9）：

`fetchCurrentUser` 发 1 个 `/api/user/profile`。`fetchSubscriptionSummary` 又发 1 个 `/api/user/profile`。`fetchDashboardStats` 发 `/api/user/profile`、`/api/user/usage/records/summary`、`/api/user/request-usage` 共 3 个。`fetchUsageTrend` 发 1 个 7 天窗口的 `/api/user/usage/insights/overview`。`fetchModelUsage` 发 1 个 `/api/user/usage/insights/diagnostics`。`fetchRealtimeMetrics` 发 `/api/user/request-usage` 和 1 小时窗口的 `/api/user/usage/insights/overview` 共 2 个。`fetchAccountHealth` 直接返回 `nil`，发 0 个。

合计 9 个，其中 `/api/user/profile` 重复了 3 次、`/api/user/request-usage` 重复了 2 次。两个 overview 调用的时间窗口不同（7 天用于趋势图、1 小时用于实时指标），是合理的两次调用，不属于重复。

按默认 15 秒刷新间隔算，这是 36 请求/分钟，其中 8 个请求纯属浪费。

### 今日等于累计的成因

`fetchDashboardStats`（`Sources/Sub2APIStatusCore/DataProvider.swift:87-100`）只取了一个“过去 24 小时”的窗口，然后 `CodexProxyAdapters.toDashboardStats`（`CodexProxyAdapters.swift:65-101`）把同一份 summary 同时填进了 `total*` 和 `today*` 两套字段，例如第 80 行 `totalRequests: Int64(summary.requests)` 与第 88 行 `todayRequests: Int64(summary.requests)`。

除了两套数字恒等，“过去 24 小时”本身也不等于“今日”：下午 3 点刷新时它统计的是昨天下午 3 点到现在，跨越了两个自然日。

### 术语约定

“逻辑请求”指客户端发起的一次调用；“尝试”指代理实际向上游发出的一次调用。上游失败重试时，一次逻辑请求会对应多次尝试。`/records/summary` 把两者分开报在 `logicalRequests` 与 `attempts` 两段里（`CodexProxyModels.swift:536-537`）。已确认 `/usage/records` 返回的是尝试级记录，因此任何请求计数都不能从 records 推导，必须取 `logicalRequests` 或 diagnostics 的 `requestCount`。本计划不读 records，此约定仅为日后参考。

## 工作计划

四个里程碑按顺序推进，每个都可独立验证。里程碑 1 是后续所有工作的前提：它建立的缓存让里程碑 2 的第二次 summary 调用“被前面省下的请求抵掉”，也让里程碑 3 能零成本复用 overview。

里程碑 1 建立请求合并层。完成后请求数为 6，界面行为完全不变——这是一个纯粹的等价重构，因此它的验证标准是“请求数下降且所有现有测试仍然通过”。

里程碑 2 分离今日与当月。完成后请求数为 7，界面上今日与累计开始显示不同的数字。

里程碑 3 填充两个恒零字段。完成后请求数仍为 7，界面上 Avg Response 与 TPM 开始有值。

里程碑 4 只改注释与文档，不改行为。

## 具体步骤

以下所有命令的工作目录都是仓库根目录 `/Users/lay/dev/workSpace/swift/Sub2APIStatusBar`。

本机的 `~/.zshrc` 在非交互 shell 中会因 gvm 报 `ERROR: GVM_ROOT not set`，污染命令输出。因此每条命令都要加前缀 `source /Users/lay/.zshrc >/dev/null 2>&1 && `，把 gvm 的报错先吞掉。下文命令均已包含该前缀。

### 里程碑 1：请求合并层

新建文件 `Sources/Sub2APIStatusCore/CodexProxyRequestCache.swift`，实现一个 actor，它持有 `CodexProxyClient`，并对四类请求做“同实例内只发一次”的合并。

关键设计点是缓存 `Task` 而不是缓存结果值。因为 `MonitorViewModel` 用 `async let` 并发发起全部 7 个 fetch，三个 `/api/user/profile` 请求几乎是同时到达的；如果只缓存结果值，第二、三个调用会在第一个还没返回时就发现缓存为空，从而各自再发一次请求，合并就失效了。缓存 `Task` 则让后到的调用直接 `await` 同一个正在飞行的任务。

按窗口区分的请求（summary 与 overview）用 `"\(startTime.timeIntervalSince1970)-\(endTime.timeIntervalSince1970)"` 作为字典键，这样今日窗口与当月窗口是两个独立条目，而里程碑 3 复用 1 小时 overview 时能精确命中同一个键。

结构如下（`diagnostics` 每轮只被调用一次，无需合并，但一并纳入以便统一计数与测试）：

    actor CodexProxyRequestCache {
        private let client: CodexProxyClient
        private var profileTask: Task<CodexProxyUserProfile, Error>?
        private var requestUsageTask: Task<[CodexProxyRequestUsage], Error>?
        private var summaryTasks: [String: Task<CodexProxyUsageSummary, Error>] = [:]
        private var overviewTasks: [String: Task<CodexProxyUsageOverview, Error>] = [:]

        init(client: CodexProxyClient) { self.client = client }

        func profile() async throws -> CodexProxyUserProfile {
            if let profileTask { return try await profileTask.value }
            let task = Task { try await client.userProfile() }
            profileTask = task
            return try await task.value
        }
    }

`requestUsage()`、`summary(startTime:endTime:)`、`overview(startTime:endTime:)` 照同一模式实现。注意 `profileTask = task` 必须写在 `await task.value` 之前，否则并发调用者仍会各自建任务。

然后改造 `Sources/Sub2APIStatusCore/DataProvider.swift:70-153`：`CodexProxyDataProvider` 保持 `struct`，但把 `private let client: CodexProxyClient` 换成 `private let cache: CodexProxyRequestCache`。struct 持有一个 `let` actor 引用仍然满足 `DataProvider` 的 `Sendable` 约束，不需要改成 class 或 actor。初始化器改为：

    public init(config: AppConfig, session: URLSession = CodexProxyClient.defaultSession) {
        self.cache = CodexProxyRequestCache(client: CodexProxyClient(config: config, session: session))
    }

把七个 fetch 方法里所有 `client.userProfile()` 换成 `cache.profile()`，`client.requestUsage()` 换成 `cache.requestUsage()`，`client.usageSummary(...)` 换成 `cache.summary(...)`，`client.usageOverview(...)` 换成 `cache.overview(...)`。`client.usageDiagnostics(...)` 换成 `cache.diagnostics(...)`。

`fetchRealtimeMetrics`（`DataProvider.swift:135-147`）目前调用 `usage.entry(for: nil)`，即“取数组第一条”。既然 profile 现在是零成本的缓存读取，把它改成 `entry(for: try? await cache.profile().id)` 更准确；但若 profile 请求失败会连带拖垮实时指标，因此用 `try?` 降级为 `nil`，保持与现状同等的健壮性。

验证请求数是否真的降到 6，新建 `Tests/Sub2APIStatusCoreTests/CodexProxyRequestBudgetTests.swift`。

这个测试需要一个能计数的 `URLProtocol` 桩。由于 Swift 6 严格并发下静态可变状态会报错，计数器要用带锁的引用类型并显式标注 `@unchecked Sendable`：

    final class PathCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [String: Int] = [:]
        func record(_ path: String) {
            lock.lock(); defer { lock.unlock() }
            counts[path, default: 0] += 1
        }
        func count(_ path: String) -> Int {
            lock.lock(); defer { lock.unlock() }
            return counts[path] ?? 0
        }
        var total: Int {
            lock.lock(); defer { lock.unlock() }
            return counts.values.reduce(0, +)
        }
    }

桩 `URLProtocol` 子类在 `startLoading()` 里调用 `counter.record(request.url!.path)`，然后按路径返回对应的固件 JSON 与 HTTP 200。固件可直接复用 `Tests/Sub2APIStatusCoreTests/CodexProxyTests.swift` 里已有的测试 JSON；建议把 `overviewJSON` 从 `private` 改为 internal（去掉 `private`）以便跨文件复用，或在新文件里另建一份精简固件。二者皆可，选前者可减少重复。

会话构造要与生产一致：

    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpShouldSetCookies = false
    configuration.httpCookieAcceptPolicy = .never
    configuration.protocolClasses = [StubProtocol.self]

测试主体要复刻 `MonitorViewModel.userSnapshot` 的并发调用模式（`MonitorViewModel.swift:87-101`）。注意 `MonitorViewModel` 属于可执行 target，测试 target 只依赖 `Sub2APIStatusCore`，因此无法直接调用它，只能复刻。请在测试文件顶部写明这一耦合：若 `userSnapshot` 的调用模式变化，本测试需同步更新。

断言：`counter.count("/api/user/profile") == 1`、`counter.count("/api/user/request-usage") == 1`、`counter.total == 6`。

运行验证：

    source /Users/lay/.zshrc >/dev/null 2>&1 && swift build

    source /Users/lay/.zshrc >/dev/null 2>&1 && swift test

预期 `swift test` 输出中包含类似 `Test run with N tests passed` 的行，且 `CodexProxyTests.swift` 里原有的全部测试仍然通过——里程碑 1 是等价重构，不应有任何既有断言失败。

### 里程碑 2：分离今日与当月累计

在 `Sources/Sub2APIStatusCore/CodexProxyAdapters.swift` 的 `CodexProxyDate` 里（文件末尾，第 204 行起）新增两个窗口计算函数：

    static func todayWindow(now: Date = Date(), calendar: Calendar = .current) -> (start: Date, end: Date) {
        (calendar.startOfDay(for: now), now)
    }

    static func monthToDateWindow(now: Date = Date(), calendar: Calendar = .current) -> (start: Date, end: Date) {
        let components = calendar.dateComponents([.year, .month], from: now)
        let start = calendar.date(from: components) ?? calendar.startOfDay(for: now)
        return (start, now)
    }

两个函数都接受注入的 `now` 与 `calendar`，这样测试可以固定时间与时区，不受运行机器影响。用本地时区而非 UTC：用户在东八区，服务端的日额度也按北京时间零点重置，本地零点与之一致。

改造 `Sources/Sub2APIStatusCore/DataProvider.swift:87-100` 的 `fetchDashboardStats`，把单次调用换成两次不同窗口的 summary，并让它们并发发出：

    public func fetchDashboardStats() async throws -> DashboardStats {
        let today = CodexProxyDate.todayWindow()
        let month = CodexProxyDate.monthToDateWindow()

        async let profileTask = cache.profile()
        async let todayTask = cache.summary(startTime: today.start, endTime: today.end)
        async let monthTask = cache.summary(startTime: month.start, endTime: month.end)
        async let realtimeTask = cache.requestUsage()

        let profile = try await profileTask
        return CodexProxyAdapters.toDashboardStats(
            todaySummary: try await todayTask,
            monthSummary: try await monthTask,
            profile: profile,
            realtimeUsage: (try? await realtimeTask)?.entry(for: profile.id)
        )
    }

相应地把 `CodexProxyAdapters.toDashboardStats`（`CodexProxyAdapters.swift:65-101`）的签名从单个 `summary:` 改为 `todaySummary:` 与 `monthSummary:` 两个参数。`total*` 系列字段全部取 `monthSummary`，`today*` 系列全部取 `todaySummary`。同时删掉第 88 行那句已经过时的注释 `// Summary window is already ~1 day`。

注意 `月初 == 今日零点` 的边界情况：每月 1 日两个窗口完全相同，缓存键也相同，因此当天只会发 1 次 summary 请求而不是 2 次，当月与今日显示相同数字。这是正确行为，不是 bug；在测试中显式覆盖这一天以防日后被误改。

请求数计算：里程碑 1 后为 6，此处 summary 从 1 次变 2 次，合计 7。同步更新里程碑 1 测试里的 `counter.total` 断言为 7，并新增断言 `counter.count("/api/user/usage/records/summary") == 2`。

新增窗口计算的单元测试到 `Tests/Sub2APIStatusCoreTests/CodexProxyTests.swift`：构造一个固定的 `Date` 与东八区 `Calendar`，断言 `todayWindow` 的 start 是当天 00:00、`monthToDateWindow` 的 start 是当月 1 日 00:00，并单独断言 1 日当天两个 window 相等。

再新增一个适配器测试，直接调用 `toDashboardStats`，传入两份数值不同的 `CodexProxyUsageSummary`，断言 `todayRequests != totalRequests` 且各自等于对应来源。构造 `CodexProxyUsageSummary` 可用它已有的 `init(logicalRequests:attempts:)`（`CodexProxyModels.swift:544`）。

### 里程碑 3：填充 averageDurationMs 与 tpm

先给 `CodexProxyCostSection`（`Sources/Sub2APIStatusCore/CodexProxyModels.swift:796-832`）补一个字段。服务端已经返回了它，只是没解码：

在 `CodingKeys` 中加 `case tokensPerRequest`，声明 `public let tokensPerRequest: Double`，并在 `init(from:)` 里 `tokensPerRequest = try container.decodeIfPresent(Double.self, forKey: .tokensPerRequest) ?? 0`。对应解码测试见 `Tests/Sub2APIStatusCoreTests/CodexProxyTests.swift`。

给 `CodexProxyUsageOverview` 加一个计算属性，把 tpm 的算法与兜底集中在一处：

    public var tokensPerRequest: Double {
        if let value = cost?.tokensPerRequest, value > 0 { return value }
        guard let cost, let health, health.totalRequests > 0 else { return 0 }
        return Double(cost.totalTokens) / Double(health.totalRequests)
    }

兜底路径是为了应对服务端把 `tokensPerRequest` 返回为 `null` 或 0 的情况——此时用该窗口的总 token 除以总请求数得到同等含义的值。

然后让 `fetchDashboardStats` 额外取一份 1 小时 overview。这一步不产生新请求：`fetchRealtimeMetrics`（`DataProvider.swift:135-147`）已经在取同一个窗口，只要两处用同一个窗口计算方式，缓存键就会命中。

为保证键一致，把窗口计算也提到 `CodexProxyDate` 里，两个方法都调它：

    static func realtimeWindow(now: Date = Date(), calendar: Calendar = .current) -> (start: Date, end: Date) {
        (calendar.date(byAdding: .hour, value: -1, to: now) ?? now, now)
    }

这里有一个必须注意的陷阱：`now` 取的是墙上时钟，两个方法各自调用 `realtimeWindow()` 会得到相差几毫秒的时间戳，缓存键就不同了，请求数会变成 8。因此 `realtimeWindow` 必须在一次刷新中只算一次。做法是把它算好后存进 `CodexProxyRequestCache`，由 actor 在首次被问到时惰性确定并复用：

    private var realtimeWindowCache: (start: Date, end: Date)?

    func realtimeOverview() async throws -> CodexProxyUsageOverview {
        let window = realtimeWindowCache ?? CodexProxyDate.realtimeWindow()
        realtimeWindowCache = window
        return try await overview(startTime: window.start, endTime: window.end)
    }

`fetchDashboardStats` 与 `fetchRealtimeMetrics` 都改为调用 `cache.realtimeOverview()`。在 `fetchDashboardStats` 里用 `try?` 包裹，overview 失败时降级为 `nil`，两个指标退回 0，而不是让整个 stats 失败。

最后修改 `CodexProxyAdapters.toDashboardStats`，新增一个 `realtimeOverview: CodexProxyUsageOverview?` 参数，并把第 96、99 行的两个 0 换掉：

    averageDurationMs: realtimeOverview?.averageLatencyMs ?? 0,
    uptime: 0,
    rpm: Double(realtimeUsage?.currentRpm ?? 0),
    tpm: (realtimeOverview?.tokensPerRequest ?? 0) * Double(realtimeUsage?.currentRpm ?? 0)

`averageLatencyMs` 是 `CodexProxyUsageOverview` 上已有的计算属性，取的就是 `performance.latencyP50Ms`（`CodexProxyModels.swift:697-699`）。tpm 的含义是“每分钟 token 数”，由“每请求平均 token 数”乘“当前每分钟请求数”得到，是估算值而非服务端直接给出的瞬时值。

把第 96 行原注释 `// Only published as a display string` 替换为说明为何用 P50 的一行注释，避免后人误以为这里还是缺失状态。

新增测试：复用 `overviewJSON` 固件解码出 overview，断言 `overview.tokensPerRequest == 15.0`；再调 `toDashboardStats` 传入该 overview 与 `currentRpm: 7` 的 `CodexProxyRequestUsage`，断言 `averageDurationMs` 约等于 1200.5、`tpm` 约等于 105.0。浮点断言沿用文件中既有风格 `#expect(abs(a - b) < 0.000001)`。

另需在请求预算测试中断言窗口复用生效：`counter.count("/api/user/usage/insights/overview") == 2`（一个 7 天窗口、一个 1 小时窗口），且 `counter.total` 仍为 7。这条断言是里程碑 3 最容易出错之处的守门人。

### 里程碑 4：记录储备项与放弃项

在 `Sources/Sub2APIStatusCore/CodexProxyModels.swift` 的 `CodexProxyUsageOverview` 定义上方补一段简短注释，说明 `attempts` 与 `providers` 两段服务端有返回但当前故意不解码，并指向本计划文件路径 `docs/plans/codex-proxy-request-budget.md`。注释保持一到两行，不要展开成大段说明。

在 `CodexProxyAdapters.toModelUsageSummaries`（`CodexProxyAdapters.swift:127-145`）已有的注释上补一句：per-model token 拆分只能靠 records 聚合，已因请求预算原因放弃。

不要为此新增任何 `.md` 文档；本计划文件本身就是记录载体。

## 验证与验收

每个里程碑都必须跑通编译与测试：

    source /Users/lay/.zshrc >/dev/null 2>&1 && swift build

    source /Users/lay/.zshrc >/dev/null 2>&1 && swift test

`swift build` 预期无警告无错误地结束。Swift 6 严格并发下，如果 `CodexProxyRequestCache` 的 actor 隔离或测试桩的 `Sendable` 标注有问题，这里会直接报错，不会静默通过。

全部里程碑完成后的自动化验收标准是三条断言同时成立：一次完整的快照抓取共发出 7 个请求；`/api/user/profile` 与 `/api/user/request-usage` 各只出现 1 次；`/api/user/usage/records/summary` 出现 2 次、`/api/user/usage/insights/overview` 出现 2 次。

人工验收需要一个真实的 codexProxy 账号，因为上述测试全部跑在桩数据上，无法证明真实服务端接受我们构造的时间窗口。步骤是：构建并运行应用，打开菜单栏面板，确认四点。第一，“Today Cost”与其下方的“Total”显示不同数值，且 Total 不小于 Today。第二，“Avg Response”显示非零毫秒或秒数。第三，“Performance”一栏的 TPM 非零（需账号在最近一小时内有实际调用，否则 RPM 为 0 导致 TPM 也为 0，这属于预期行为）。第四，面板不出现连接错误——若服务端拒绝当月窗口的时间范围，会以 `40001` 参数错误的形式暴露出来。

请求数的真实环境复核可用一次抓包或临时日志完成，不必长期保留该日志代码。

若某个里程碑的测试失败但改动方向正确，不要为了让测试变绿而放宽断言，特别是 `counter.total` 这条——它是本计划唯一的硬约束。

## 幂等性与恢复

本计划的全部改动都是仓库内的源码编辑，没有数据迁移、没有外部系统写入、没有不可逆操作。任何一步都可以用 git 回退。

开工前请先确认工作区状态，因为仓库当前已有多个未提交的修改（包括未跟踪的 `Tests/Sub2APIStatusCoreTests/CodexProxyTests.swift`）：

    source /Users/lay/.zshrc >/dev/null 2>&1 && git status

若需要中断并保留现场，用带唯一标签的 stash 而非裸 `git stash`，并且只恢复自己创建的那一条。

建议每个里程碑单独提交，这样回退粒度与验证粒度一致。提交前请勿包含 `config.json` 之类可能含密码的文件——本项目将 codexProxy 的登录密码明文存于配置文件中，该文件不应进入版本库。

里程碑之间的依赖是单向的：里程碑 2 依赖里程碑 1 建立的 `cache.summary(startTime:endTime:)`，里程碑 3 依赖里程碑 1 的 overview 合并。若中途放弃，停在任意一个已通过验证的里程碑上都是可交付状态。

重复执行本计划的步骤是安全的：所有编辑都是幂等的目标态描述，不是增量补丁。

## 产物与备注

新增文件两个：`Sources/Sub2APIStatusCore/CodexProxyRequestCache.swift` 与 `Tests/Sub2APIStatusCoreTests/CodexProxyRequestBudgetTests.swift`。

修改文件四个：`Sources/Sub2APIStatusCore/DataProvider.swift`、`Sources/Sub2APIStatusCore/CodexProxyAdapters.swift`、`Sources/Sub2APIStatusCore/CodexProxyModels.swift`、`Tests/Sub2APIStatusCoreTests/CodexProxyTests.swift`。

不修改任何 SwiftUI 视图文件，不修改 `Sources/Sub2APIStatusCore/Models.swift`。这是本计划范围的边界：一旦发现必须改动 `DashboardStats` 的字段定义，说明范围已经超出，应先回到“决策记录”重新评估。

`Sub2APIDataProvider` 完全不受影响，sub2api provider 的行为逐字节不变。

## 接口与依赖

### 本计划使用的 codex-proxy-rs 端点

`GET /api/user/profile` 提供额度上限与已用量、`keyCount`、`maxConcurrency`、`requestsPerMinute`、日/周重置时间。无月度额度概念，也没有余额字段。

`GET /api/user/usage/records/summary?startTime=&endTime=` 提供窗口内的聚合。顶层字段是展示字符串（如 `"1.1K"`、`"112.6M"`、`"13.69 s"`），精确数值在 `logicalRequests` 段，金额在 `attempts.costs[].estimatedAmount` 段。本计划只读后两者。

`GET /api/user/usage/insights/overview?startTime=&endTime=` 返回 `{granularity, health, performance, cost, attempts, providers}`。没有单一的 `trend` 数组，趋势要把 `health.points`（请求数）与 `cost.points`（token 与金额）按 `bucket` 合并，这已由 `CodexProxyUsageOverview.trendPoints` 实现。

`GET /api/user/usage/insights/diagnostics?dimension=model|provider` 是唯一的服务端按模型聚合。`dimension=account` 会被服务端明确拒绝。

`GET /api/user/request-usage` 返回数组，每个用户一条，含 `currentConcurrency` 与 `currentRpm`。

### 错误约定

失败以 HTTP 401 配合信封返回。`40101` 表示需要登录（会话缺失或过期，可通过静默重登恢复），`40102` 表示用户名或密码错误（不应重试），`40001` 表示查询参数非法。这套分类已由 `CodexProxyError.isUnauthorized`（`CodexProxyModels.swift:30-41`）实现，本计划不改动它。里程碑 2 引入新的时间窗口后，若窗口跨度被服务端认为过长，最可能以 `40001` 的形式暴露，人工验收时需留意。

### 确定放弃的指标及原因

各模型的 input/output/cached/cacheWrite token 拆分：diagnostics 只给 `totalTokens`，唯一来源是 records 聚合，已放弃。界面上继续省略 token 构成行，这一降级行为已有测试覆盖（`Tests/Sub2APIStatusCoreTests/CodexProxyTests.swift:266`）。

各模型的标准价与缓存节省：同上，只能来自 records 的 `billing.standardAmountDisplay`，已放弃。

route 与 transport 分布：只存在于 records 的 `route`、`clientTransport`、`upstreamTransport` 字段，已放弃。

最近一次调用的具体时间：`/api/user/client-keys` 的 `lastUsedAt` 取最大值可近似得到，但需要额外 1 个请求，不划算，已放弃。

请求级 HTTP 状态码分布：records 的记录里根本没有 `statusCode` 字段（见“意外与发现”），因此即使做 records 聚合也拿不到，彻底放弃。

### 已具备数据但暂无展示位的储备项

以下四项要么已经解码完成、要么只需补几行解码即可获得，全部零额外请求。它们没有实现，唯一原因是 `DashboardStats` 与 UI 中没有对应展示位。若日后新增展示位，可直接启用。

按错因拆分的失败计数：`attempts` 段的 `rateLimitedCount`、`authFailureCount`、`provider5xxCount`。需要给 `CodexProxyUsageOverview` 的 `CodingKeys` 补上 `attempts` 并新增一个对应结构。注意不要把它们映射到 `DashboardStats` 的 `ratelimitAccounts` / `errorAccounts` / `overloadAccounts`——那三个字段是“上游账号数量”，与“请求次数”语义不同，混用会得出错误的界面。

按 provider 的用量拆分：overview 的 `providers` 数组，含 `requestCount`、`attemptCount`、`failureCount`、`totalTokens`。

全局 reasoning token：`CodexProxyUsageSummary.reasoningTokens` 已实现（`CodexProxyModels.swift:560`），当前无调用方。

全局缓存节省与标准价：`CodexProxyCostSection.savings` 与 `standard` 已实现（`CodexProxyModels.swift:830-831`），当前无调用方。启用时须注意其窗口与 summary 的今日/当月窗口不一致，详见“决策记录”。

此外 diagnostics 的返回项里还有若干未解码字段可供将来使用：`latencyP95Ms`、`firstTokenP95Ms`、`nonCompletionCount`、`nonCompletionRate`、`retryCount`、`retryRate`、`impactScore`。其中 `retryCount` 与 `retryRate` 可用于量化“尝试与逻辑请求的差距”，是验证前述尝试级语义的现成手段。

## 修订说明

- 2026-09-17（初版实施）：里程碑 1 至 4 一次性实现完毕并通过 `swift test`。相对初始计划有两处偏离：（1）`tokensPerRequest` 的兜底计算从 `CodexProxyCostSection` 移到 `CodexProxyUsageOverview`，因为前者不含请求数，无法构成有意义的分母；（2）测试辅助函数改为解码 JSON 构造 summary，因为 `CodexProxyRequestCounts` 等结构只有 `init(from:)` 而无成员初始化器。
- 2026-09-17（服务端兼容性验证）：确认服务端接受当月窗口，记录请求计数语义与空闲窗口的 null 处理约束；不保留真实账号与用量记录。
- 2026-09-17（新增里程碑 5、6）：应用户要求追加两项工作。里程碑 5 注入时钟，消除预算测试在每月 1 日的抖动，并把该日的合并行为固化为预期。里程碑 6 推翻了原先“不为储备项新增 `DashboardStats` 字段”的决策——但只对窗口一致的两项执行，`cacheSavings` 与 provider 拆分因需穿透 `MonitorSnapshot` 而挂起。
- 2026-09-17（里程碑 6 全部回退）：应用户定性约束“UI 展示内容不变，支持不了的数据直接放弃”，里程碑 6 全部回退。`RequestFailureBreakdown`、`DashboardStats` 四个新字段、`CodexProxyAttemptCounts` 三个错因字段解码、面板两个新 tile 及其辅助方法、两个对应测试，全部删除。`Models.swift` 与 `MonitorPanel.swift` 恢复到会话前状态。原计划“不修改 `Models.swift`”的边界重新生效。

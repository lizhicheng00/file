# Relay Controller 二期详细设计

## 1 价值描述

### 作为

作为 DevBridge 控制面的架构师、测试人员和开发人员。

### 我要

我要在一期 Tunnel、Port 和 Token 管理能力之上，增加账户、套餐、流量计量结算、额度查询和运行状态展示能力。

### 从而

- 用户可以明确看到当前限制和月度剩余额度；
- Relay Gateway 可以按统一规则执行连接、带宽和流量限制；
- 多 Region、多副本部署时，Tunnel 配额和流量结算仍保持一致；
- 原始计量、分钟用量和月度余额形成可追溯的业务闭环。

### 现状

一期已经提供 Tunnel、Port、Token 和 mTLS 能力，但缺少以下闭环：

- `namespace` 尚未形成明确的计费账户；
- Tunnel 和 Port 数量限制缺少统一套餐来源；
- Gateway 产生的流量没有稳定、幂等的结算流程；
- 用户无法查询月度额度和数据面限制；
- Tunnel 详情缺少 Host、客户端连接数和实时速率。

二期不再通过 Relay Controller 接收计量或状态上报。Relay Gateway 与 Relay Controller 共用数据库，由 Gateway 直接写入原始计量和最新运行状态，Controller 负责结算、查询和控制面校验。

### 要求

二期默认提供一套 `trial` 套餐：

| 项目 | 限制 |
| --- | ---: |
| 每月流量 | 5 GiB |
| 每个账户的有效 Tunnel | 10 |
| 每个 Tunnel 的 Port | 10 |
| 每个 Tunnel 的 Host 连接 | 1 |
| 每个 Tunnel 的带宽 | 5 MiB/s |
| 每个 Port 的 HTTP 请求 | 500 次/分钟 |
| 每个 Port 的并发连接 | 100 |

同时满足以下要求：

- Gateway 每 30 秒上报一次增量流量，Host 会话结束时补充上报；
- Controller 每分钟结算一次，允许余额存在约一个结算周期的延迟；
- 月度额度按 UTC 自然月计算，新月份创建新账期，不修改旧账期；
- 多个 Controller 实例可以并行结算，不能重复计费；
- Tunnel 详情返回 Gateway 最近一次上报的运行状态；
- 二期保持一期 API 路径兼容，不新增计量和状态上报 HTTP 接口。

## 2 功能描述

### 2.1 功能说明

#### 账户与套餐

- 一个 `namespace` 对应一个计费账户；
- 账户首次使用时自动创建，并绑定默认 `trial` 套餐；
- 套餐统一保存月度额度、Tunnel/Port 数量和数据面限制；
- 账户可被禁用，禁用后不能创建 Tunnel 或签发 Token。

#### Tunnel 与 Port 配额

- 创建 Tunnel 前校验账户状态和有效 Tunnel 数量；
- 创建 Port 前校验所属 Tunnel 和当前 Port 数量；
- 通过数据库行锁串行化同一账户或 Tunnel 的并发创建，避免多副本下突破配额；
- 已过期或已删除的 Tunnel 不计入有效 Tunnel 数量。

#### 流量计量与结算

- Gateway 只上报本次周期新增的字节数，不上报会话累计值；
- 原始数据写入 `tunnel_metering`，同一条上报可安全重试；
- Controller 将原始数据按账户、Tunnel 和 UTC 分钟聚合；
- 每批数据在同一事务内更新分钟用量、月度用量和原始数据结算标记；
- 结算失败时整体回滚，原始数据保留为未结算状态，下一轮继续处理。

#### 限制与余额

`GET /limits` 返回：

- 本月总额度、剩余额度和下次重置时间；
- 当前有效 Tunnel 数量；
- Tunnel、Port、Host、带宽、HTTP 请求和连接限制。

余额以已结算数据为准：

```text
remainingBytes = max(0, quotaBytes - billedBytes)
```

#### Tunnel 运行状态

Gateway 将每个 Tunnel 的最新状态写入 `tunnel_runtime_status`。Tunnel 详情可返回：

- Host 连接数；
- 客户端连接数，当前以活动 SSH Channel 数表示；
- 当前上传、下载速率；
- 状态上报时间。

状态是运行观测数据，不作为计费依据。没有状态记录时，Tunnel 详情不返回 `status`；过期状态由定时清理任务删除。

#### Token 与额度

- `host` 和 `connect` Token 每次调用均重新签发；
- Token 有固定配置的有效期，不跟随 Tunnel 剩余有效期变化；
- 签发前校验 Tunnel、账户状态和月度额度；
- JWT 的 `aud` 为 `relay-gateway`，Gateway 必须校验签名、有效期、`aud`、Tunnel、Cluster 和 Scope；
- `forCookies=true` 只标识交付方式，当前 Token 仍是签名 JWT，Claims 可被读取；
- Cookie 写入以及后续可选的 JWE 加密由用户入口和 Gateway 协同实现，不属于本次已实现范围。

### 2.2 约束与依赖

#### 系统边界

| 组件 | 二期职责 |
| --- | --- |
| Relay Controller | 账户和套餐、元数据配额、分钟结算、月度余额、Token 校验、限制查询、状态展示 |
| Relay Gateway | Host 侧流量统计、计量和状态写库、单 Host 锁、带宽/HTTP/连接限流、超额拒绝和断连、原始计量老化 |
| CLI | Echo、Ping、随机端口、Verbose 日志和本地 HTTP Server，不在 Controller 范围 |

#### 依赖

- Relay Controller 与 Relay Gateway 使用同一套 MySQL/MariaDB；
- 数据库必须支持 InnoDB、事务、`FOR UPDATE SKIP LOCKED` 和唯一索引；
- Cluster 基础数据必须提前存在，并正确绑定 Region；
- 所有计量时间使用 Unix 秒，账期和分钟窗口统一按 UTC 计算；
- Gateway 必须从 `tunnel` 表获取 `account_id` 和 `cluster_id`，不能信任外部传入的归属信息；
- Controller 可多副本部署，不依赖单机内存保存计费状态。

#### 一致性边界

- 余额基于已结算流量，默认最多延迟约一分钟；
- Gateway 在新连接建立时检查额度，并根据共享账期状态执行拒绝或断连；
- 已签发 JWT 不会因额度耗尽而自动失效，实时限制由 Gateway 执行；
- Gateway 只能清理已结算且超过 7 天的原始计量数据；
- 首版通过索引控制计量表查询范围，暂不分区；
- mTLS 证明调用方服务身份，不直接证明 `X-Namespace` 的用户归属；生产入口仍需保证该请求头可信。

## 3 实现设计

### 3.1 总体设计描述

二期采用“Gateway 采集、数据库缓冲、Controller 结算、Gateway 执行”的闭环：

```text
Host 流量
   |
   v
Relay Gateway --增量计量--> tunnel_metering
   |                              |
   |--最新状态--------------> tunnel_runtime_status
                                  |
                                  v
                         Relay Controller 每分钟结算
                                  |
                  +---------------+---------------+
                  v                               v
          billing_usage_1m                 billing_period
                                                  |
                          +-----------------------+------------------+
                          v                                          v
                    GET /limits                              Token/连接额度判断
```

设计原则：

- 原始计量只追加，聚合结果单独保存；
- 是否完成结算由原始记录的 `settled` 标记确定；
- 同一批聚合和标记在一个事务中完成；
- 配额来源统一为 `billing_plan`，避免 Controller 与 Gateway 各自维护常量；
- Region 归属在 SQL 查询阶段过滤，不先查全量数据再在内存筛选。

### 3.2 业务流程

#### 流程一：创建 Tunnel

1. 校验 `X-Namespace`、Cluster 和请求参数；
2. 不存在账户时创建账户并绑定默认套餐；
3. 锁定账户记录；
4. 查询当前有效 Tunnel 数量；
5. 达到套餐上限时返回配额错误；
6. 创建 Tunnel，并写入 `account_id`；
7. 事务提交后释放账户锁。

验收重点：同一账户并发创建、多个 Controller 实例并发创建时，有效 Tunnel 总数不能超过 10。

#### 流程二：创建 Port

1. 按 Region、Namespace 和 Tunnel ID 查询并锁定 Tunnel；
2. 校验 Tunnel 未过期、Port 不重复；
3. 查询套餐和当前 Port 数量；
4. 达到上限时返回配额错误，否则创建 Port；
5. 刷新 Tunnel 的活动过期时间。

验收重点：同一 Tunnel 并发创建不同 Port 时，Port 总数不能超过 10。

#### 流程三：Gateway 上报计量

1. Gateway 每 30 秒计算自上次成功上报后的增量字节数；
2. 从有效 Tunnel 记录中取得 `account_id`、`cluster_id` 和 `tunnel_id`；
3. 写入一条 `tunnel_metering`；
4. 写入失败时保留本地增量并重试；
5. 精确重试必须复用相同的 `session_id`、`reported_at` 和 `usage_bytes`；
6. Host 会话结束时上报尚未成功写入的剩余增量。

验收重点：网络重试不能重复计费；同一会话在同一秒最多形成一条上报。

#### 流程四：每分钟结算

1. 每个 Controller 实例按批次锁定本 Region 的未结算记录；
2. `SKIP LOCKED` 跳过其他实例正在处理的记录；
3. 按账户、Tunnel 和分钟窗口合并字节数；
4. 创建或读取对应 UTC 月度账期；
5. 累加 `billing_period`、`billing_usage_1m` 和 Tunnel 已用流量；
6. 将本批原始记录更新为 `settled=1`；
7. 提交事务，并继续处理下一批，直到当前积压不足一个批次。

验收重点：结算中途异常必须全部回滚；多实例并行结算后，聚合总量必须等于原始未重复记录总量。

#### 流程五：额度查询与执行

1. Controller 根据当前 UTC 时间定位自然月账期；
2. 读取套餐额度和已结算字节数；
3. 返回余额、重置时间和各项限制；
4. Token 签发时拒绝已禁用或已超额账户；
5. Gateway 在连接建立和运行过程中读取共享额度状态，执行拒绝、限速或断连。

验收重点：跨月后自动使用新账期，旧账期数据不清零、不覆盖。

#### 流程六：运行状态展示

1. Gateway 按 Tunnel 覆盖写入最新状态，只接受时间不早于当前记录的上报；
2. Controller 查询 Tunnel 详情时关联最新状态；
3. 状态不存在时仅返回 Tunnel 元数据；
4. 清理任务删除已删除 Tunnel 的状态和超过保留时间的状态。

验收重点：乱序上报不能覆盖较新的状态；状态缺失不能影响 Tunnel 详情查询。

### 3.3 关键业务算法

#### 计量幂等键

```text
uniqueKey = tunnelId + sessionId + reportedAt
```

`usageBytes` 表示增量值。Gateway 对同一次重试必须保持幂等键和流量值不变，唯一索引负责消除重复写入。

#### 分钟归档

```text
windowStart = reportedAt - reportedAt % 60
```

同一账户、Tunnel、分钟内的计量记录合并到一条 `billing_usage_1m`。

#### 月度账期

```text
periodStart = UTC 当月 1 日 00:00:00
periodEnd   = UTC 下月 1 日 00:00:00
```

流量按 `reportedAt` 所在月份归档。跨月时创建新账期，不执行“清零旧记录”的定时任务。

#### 多副本结算

- `FOR UPDATE` 在事务结束时释放行锁；
- `SKIP LOCKED` 使不同实例取得不同原始记录，避免互相等待；
- 聚合更新和 `settled` 标记共享事务，提交成功后才视为完成；
- 事务回滚后记录仍为未结算，可在下一轮重新处理。

#### 配额并发控制

- Tunnel 配额：锁定 `billing_account` 后统计并创建；
- Port 配额：锁定所属 `tunnel` 后统计并创建；
- 锁的粒度与配额归属一致，避免使用单 JVM 锁。

### 3.4 关键代码

关键实现入口如下：

| 类 | 职责 |
| --- | --- |
| `BillingService` | 创建/锁定账户、读取套餐、创建月度账期、计算余额 |
| `BillingSettlementJob` | 每分钟触发结算并排空当前积压 |
| `BillingSettlementService` | 锁定、聚合、入账和标记原始计量 |
| `LimitsAppService` | 组装限制与余额 |
| `TunnelAppService` | Tunnel 配额、Token 额度校验、详情状态查询 |
| `TunnelPortAppService` | Port 配额和 Gateway Port 策略查询 |
| `TunnelCleanupJob` | 过期 Tunnel 和陈旧运行状态清理 |

结算事务只保留一个核心原则：

```text
begin transaction
  records = lock unsettled rows skip locked
  aggregate records by account + tunnel + minute
  update monthly period and minute usage
  mark the same records settled
commit
```

任何一步失败都回滚，不单独提交聚合结果或结算标记。

### 3.5 接口定义

接口统一前缀：

```text
/open-api-inner/v1/relay-controller
```

二期相关 HTTP 接口：

| 方法与路径 | 调用方 | 主要输入 | 主要输出与规则 |
| --- | --- | --- | --- |
| `POST /tunnels` | 用户入口 | `X-Namespace`、Cluster、Tunnel 信息 | 创建账户关联并校验最多 10 个有效 Tunnel |
| `GET /tunnels` | 用户入口 | `X-Namespace`、可选 `clusterId` | Tunnel 列表，包含 `portCount` 和过期信息 |
| `GET /tunnels/{tunnelId}` | 用户入口 | `X-Namespace`、Tunnel ID | Tunnel 详情；有最新状态时返回 `status` |
| `POST /tunnels/{tunnelId}/token` | 用户入口 | `scope=host\|connect`、可选 `forCookies` | 每次返回新 Token；超额或账户禁用时拒绝 |
| `POST /tunnels/{tunnelId}/ports` | 用户入口 | Port、Protocol、匿名策略 | 校验每个 Tunnel 最多 10 个 Port |
| `GET /clusters/{clusterId}/tunnels/{tunnelId}/ports/{port}` | Gateway | Cluster、Tunnel、Port | 返回 Protocol 和匿名访问策略 |
| `GET /limits` | 用户入口 | `X-Namespace` | 返回月度余额、重置时间和套餐限制 |

`GET /limits` 的关键返回字段：

| 字段 | 含义 |
| --- | --- |
| `resetAt` | 当前 UTC 月度账期结束时间，Unix 秒 |
| `quotaBytes` | 本账期总额度 |
| `remainingBytes` | 已结算口径的剩余额度 |
| `activeTunnels` / `maxTunnels` | 当前有效 Tunnel 数量及上限 |
| `maxPortsPerTunnel` | 单 Tunnel Port 上限 |
| `maxHostsPerTunnel` | 单 Tunnel Host 上限 |
| `maxTunnelBandwidthBytesPerSecond` | 单 Tunnel 带宽上限 |
| `maxHttpRequestsPerMinutePerPort` | 单 Port HTTP 请求上限 |
| `maxConnectionsPerPort` | 单 Port 并发连接上限 |

Gateway 数据库写入契约：

| 目标表 | 写入方式 | 约束 |
| --- | --- | --- |
| `tunnel_metering` | 每 30 秒追加增量记录，会话结束补充写入 | 从 `tunnel` 取得账户和 Cluster；精确重试保持相同幂等键 |
| `tunnel_runtime_status` | 按 `tunnel_id` 更新最新值 | 仅接受不早于现有 `reported_at` 的状态 |
| `tunnel` | Host 活动期间按粒度刷新过期时间 | 仅更新有效且属于当前 Cluster 的 Tunnel |

Relay Controller 不提供 `/metering` 或 `/tunnels/status` 上报接口。OpenAPI YAML 是 HTTP 接口的最终契约。

### 3.6 数据表设计

#### 二期新增及变更表

| 表 | 作用 | 主键/唯一约束 | 生命周期 |
| --- | --- | --- | --- |
| `billing_plan` | 套餐及全部限制的统一来源 | `plan_code` | 配置数据，长期保留 |
| `billing_account` | `namespace` 与套餐的绑定 | `_id`；`namespace` 唯一 | 账户数据，长期保留 |
| `billing_period` | 账户 UTC 月度额度和已结算流量 | `account_id + period_start` | 月度账单结果，长期保留 |
| `tunnel_metering` | Gateway 原始增量计量 | `_id`；`tunnel_id + session_id + reported_at` 唯一 | 已结算数据保留 7 天后由 Gateway 分批清理 |
| `billing_usage_1m` | Tunnel 分钟级结算结果 | `account_id + tunnel_id + window_start` | 计费聚合结果，长期保留 |
| `tunnel_runtime_status` | Tunnel 最新运行状态 | `tunnel_id` | 覆盖更新，陈旧或孤立状态定时删除 |
| `tunnel` | 新增账户归属 | 原有主键；新增 `account_id` 索引 | 延续一期生命周期 |

#### 核心字段

`billing_account`

| 字段 | 说明 |
| --- | --- |
| `_id` | 账户内部 ID |
| `namespace` | 用户隔离范围，一个 Namespace 一个账户 |
| `plan_code` | 当前套餐 |
| `status` | `active` 或 `disabled` |

`billing_period`

| 字段 | 说明 |
| --- | --- |
| `account_id` | 账户 ID |
| `period_start` / `period_end` | UTC 月度区间，左闭右开 |
| `quota_bytes` | 创建账期时保存的额度快照 |
| `billed_bytes` | 已结算流量 |

`tunnel_metering`

| 字段 | 说明 |
| --- | --- |
| `_id` | 结算批次选择和排序使用的自增 ID |
| `account_id` / `cluster_id` / `tunnel_id` | 计量归属 |
| `session_id` | Host 连接会话 ID |
| `usage_bytes` | 本次新增流量 |
| `reported_at` | Gateway 统计时间，Unix 秒 |
| `created_at` | 数据库写入时间，Unix 秒 |
| `settled` | `0` 未结算，`1` 已结算 |

`billing_usage_1m`

| 字段 | 说明 |
| --- | --- |
| `account_id` / `tunnel_id` | 用量归属 |
| `window_start` | UTC 分钟起始时间 |
| `usage_bytes` | 该分钟已结算流量 |

`tunnel_runtime_status`

| 字段 | 说明 |
| --- | --- |
| `tunnel_id` | Tunnel ID |
| `host_connection_count` | 当前 Host 连接数 |
| `client_connection_count` | 当前活动 SSH Channel 数 |
| `upload_bytes_per_second` | 当前上传速率 |
| `download_bytes_per_second` | 当前下载速率 |
| `reported_at` | Gateway 状态时间 |

#### 索引与容量

- `tunnel_metering(settled, created_at, _id)` 支持按状态、时间和批次顺序结算；
- `tunnel_metering(account_id, reported_at)` 支持账户和时间范围核查；
- `billing_usage_1m(account_id, window_start)` 支持账户分钟用量查询；
- `tunnel_runtime_status(reported_at)` 支持陈旧状态清理；
- 首版不做分区。只有当 7 天保留量使索引和批量清理无法满足目标时，再按实际容量评估时间分区。

历史一期 `metering` 表由 V3 迁移删除，避免两套计量口径并存。

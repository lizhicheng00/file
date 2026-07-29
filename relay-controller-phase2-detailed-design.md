# Relay Controller 二期详细设计

本文描述 Relay Controller 二期需要交付的业务能力，供 SE 评审设计、测试设计用例、关联服务开发对齐接口和数据契约。文档只描述 Relay Controller 的实现范围；Gateway 和 CLI 仅保留与本服务有关的协作边界。

## 1 价值描述

### 作为

作为 DevBridge 隧道服务的用户。

### 我要

我要在使用 Tunnel 时，能够查看账户限制和月度流量余额，并由系统自动完成流量统计、额度控制和运行状态展示。

### 从而

- 明确知道当前可以创建多少 Tunnel 和 Port；
- 明确知道本月流量额度、剩余额度和重置时间；
- 在多 Region、多副本部署下获得一致的配额和计量结果；
- 在 Tunnel 详情中了解当前连接数和网络速率；
- 超出限制时得到明确、可执行的拒绝结果。

### 现状

一期已经具备 Tunnel、Port 和 Token 管理能力，但还没有形成完整的资源与流量管理闭环：

- `namespace` 没有对应的账户和套餐；
- Tunnel、Port 和数据面限制缺少统一来源；
- Gateway 产生的流量没有稳定的结算结果；
- 用户无法查询本月额度和剩余流量；
- Tunnel 详情无法展示 Gateway 的最新运行状态。

### 要求

二期需要实现以下内容：

| 能力 | 默认规格 |
| --- | ---: |
| 月度流量额度 | 5 GiB |
| 每个账户的有效 Tunnel | 10 |
| 每个 Tunnel 的 Port | 10 |
| 每个 Tunnel 的 Host 连接 | 1 |
| 每个 Tunnel 的带宽 | 5 MiB/s |
| 每个 Port 的 HTTP 请求 | 500 次/分钟 |
| 每个 Port 的并发连接 | 100 |
| Gateway 计量周期 | 30 秒 |
| Controller 结算周期 | 1 分钟 |

月度额度按 UTC 自然月计算。Relay Controller 必须支持多副本运行，不能因为并发创建、重复上报或重复结算导致配额失效或流量重复累计。

## 2 功能描述

### 2.1 功能说明

#### 账户与套餐

- 一个 `namespace` 对应一个计费账户；
- 账户首次使用时自动创建，并绑定默认 `trial` 套餐；
- 套餐统一维护月度流量、Tunnel、Port、Host、带宽、HTTP 请求和连接限制；
- 账户被禁用后，不能创建 Tunnel 或签发 Token。

#### Tunnel 与 Port 配额

- 创建 Tunnel 时校验账户的有效 Tunnel 数量；
- 创建 Port 时校验所属 Tunnel 的 Port 数量；
- 并发请求到达不同 Controller 实例时，最终数量仍不能超过套餐上限；
- 已过期或已删除的 Tunnel 不占用有效 Tunnel 配额。

#### 流量计量与结算

- Gateway 在 Host 侧统计上下行流量；
- Gateway 每 30 秒写入一次增量流量，Host 会话结束时补充写入剩余流量；
- Relay Controller 每分钟读取未结算记录，生成分钟用量并累计月度用量；
- 结算成功后标记原始记录，避免再次计费；
- 结算失败时不产生部分结果，下一周期可继续处理。

#### 限制与余额

新增限制查询能力，向用户返回：

- 本月总额度、剩余额度和下次重置时间；
- 当前有效 Tunnel 数量及上限；
- Port、Host、带宽、HTTP 请求和连接上限。

余额按已结算流量计算，因此正常情况下允许约一分钟的展示延迟。

#### Tunnel 运行状态

Gateway 保存每个 Tunnel 的最新运行状态，Relay Controller 在 Tunnel 详情中返回：

- Host 连接数；
- 客户端连接数，以活动 SSH Channel 数表示；
- 当前上传和下载速率；
- 状态上报时间。

运行状态用于展示和运行判断，不作为流量计费依据。没有状态数据时，Tunnel 详情仍正常返回，只是不包含 `status`。

#### Token 额度校验

- `host` 和 `connect` Token 每次请求都重新签发；
- Token 使用固定配置的有效期，不跟随 Tunnel 剩余有效期变化；
- 签发前校验 Tunnel、账户状态和月度额度；
- 月度额度耗尽时不再签发新 Token；
- 已签发 Token 不会立即失效，正在运行的连接由 Gateway 根据共享额度状态处理。

### 2.2 约束与依赖

#### 职责边界

| 组件 | 职责 |
| --- | --- |
| Relay Controller | 账户和套餐、资源配额、流量结算、余额查询、Token 校验、Tunnel 状态展示 |
| Relay Gateway | Host 侧流量统计、计量和状态写库、单 Host、带宽、HTTP 和连接限制、超额拒绝或断连 |
| CLI | Echo、Ping、随机端口、Verbose 日志和本地 HTTP Server，不属于本项目 |

#### 依赖与约束

- Relay Controller 与 Gateway 共用 MySQL/MariaDB；
- Gateway 直接写入原始计量和最新运行状态，Controller 不提供对应的上报 HTTP 接口；
- Cluster 必须提前存在，并绑定正确的 Region；
- Controller 只结算本 Region 所属 Cluster 的数据；
- 计量时间统一使用 Unix 秒，分钟窗口和月度账期统一使用 UTC；
- Gateway 必须从 `tunnel` 表取得 `account_id` 和 `cluster_id`，不能使用外部输入决定数据归属；
- Gateway 只清理已结算且超过 7 天的原始计量数据；
- 首版使用索引和 7 天保留策略控制计量表规模，暂不进行数据库分区。

#### 安全边界

- mTLS 用于确认调用方服务身份；
- `X-Namespace` 仍需由可信入口校验并传递，不能仅依赖 mTLS 判断用户归属；
- JWT 的 `aud` 为 `relay-gateway`，Gateway 需要校验签名、有效期、Audience、Tunnel、Cluster 和 Scope；
- `forCookies=true` 只标识 Token 的交付方式，当前仍是签名 JWT，Claims 可以被读取；
- Cookie 写入和可选的 JWE 加密不属于本次 Controller 交付范围。

## 3 实现设计

### 3.1 总体设计描述

二期采用“Gateway 采集、Controller 结算、双方共享结果”的设计：

```text
Host 流量
   |
   v
Relay Gateway
   |-- 增量流量 --> tunnel_metering
   |-- 最新状态 --> tunnel_runtime_status
                         |
                         v
                Relay Controller
                   每分钟结算
                         |
             +-----------+-----------+
             v                       v
     billing_usage_1m          billing_period
                                     |
                         +-----------+-----------+
                         v                       v
                    GET /limits             Token 校验
```

核心设计原则：

- 套餐是全部限制的唯一来源；
- 原始计量与结算结果分开保存；
- 一条原始计量最多结算一次；
- 同一批计量要么全部结算成功，要么全部保留待重试；
- 多个 Controller 实例可以共同处理积压，但不能重复累计；
- Region 归属在读取计量数据时完成过滤。

### 3.2 业务流程

#### 流程一：账户与资源配额

1. 用户首次使用时，根据 `namespace` 创建账户并绑定默认套餐；
2. 创建 Tunnel 时统计该账户当前有效 Tunnel；
3. 创建 Port 时统计该 Tunnel 当前 Port；
4. 未达到限制时创建资源，达到限制时返回明确的配额错误；
5. 并发创建仍以套餐上限为最终结果。

测试重点：

- 第 10 个 Tunnel 成功，第 11 个失败；
- 同一 Tunnel 的第 10 个 Port 成功，第 11 个失败；
- 多实例并发创建后，数据总数不突破上限；
- 过期和已删除 Tunnel 不占用 Tunnel 配额；
- 禁用账户不能创建 Tunnel。

#### 流程二：Gateway 写入计量

1. Gateway 计算距离上次成功上报后新增的流量；
2. 根据有效 Tunnel 获取账户和 Cluster 归属；
3. 写入 `tunnel_metering`；
4. 写入失败时保留本地增量并重试；
5. 同一次重试使用相同的 `sessionId`、`reportedAt` 和 `usageBytes`；
6. Host 会话结束时写入尚未上报的剩余流量。

测试重点：

- 正常周期上报能够连续写入；
- 完全相同的重试只保留一条记录；
- 不同时间的增量可以分别写入；
- 无效、已删除或归属不一致的 Tunnel 不能写入；
- 会话结束上报不会与同秒周期上报重复。

#### 流程三：分钟结算

1. Controller 每分钟获取本 Region 未结算的原始数据；
2. 按账户、Tunnel 和分钟合并流量；
3. 将流量累计到分钟用量和对应月度账期；
4. 同步累计 Tunnel 已用流量；
5. 完成后将本批原始数据标记为已结算；
6. 当前积压较多时，继续分批处理直到本轮完成。

测试重点：

- 原始流量总和与分钟、月度累计结果一致；
- 同一条原始计量不会重复结算；
- 结算中途失败后不产生部分账单；
- 多实例同时结算时结果不重不漏；
- 非本 Region 的计量不由当前 Controller 处理；
- 延迟到达的数据按 `reportedAt` 归入正确分钟和月份。

#### 流程四：月度余额

1. 账户首次查询或产生计量时，创建当前 UTC 月度账期；
2. 套餐额度作为该账期的额度快照；
3. 已结算流量持续累计到当前账期；
4. 下月自动创建新账期，旧账期保持不变；
5. `/limits` 返回当前账期余额和下月开始时间。

测试重点：

- `remainingBytes` 不小于 0；
- 月末与月初数据分别进入正确账期；
- 套餐后续调整不改变已经创建的历史账期快照；
- 余额耗尽后 Token 签发被拒绝。

#### 流程五：运行状态

1. Gateway 按 Tunnel 保存最新状态；
2. 较旧的乱序状态不能覆盖较新的状态；
3. Controller 查询详情时返回当前状态；
4. 状态缺失不影响 Tunnel 元数据查询；
5. 超过保留时间或 Tunnel 已不存在的状态由清理任务删除。

测试重点：

- 连接数、上下行速率和时间能够正确返回；
- 乱序写入后仍保留最新状态；
- 无状态时响应中不包含 `status`；
- 陈旧状态能够被清理。

### 3.3 关键业务算法

#### 计量幂等

```text
唯一标识 = tunnelId + sessionId + reportedAt
```

`usageBytes` 是本次新增流量，不是会话累计流量。Gateway 重试同一次上报时必须保持唯一标识和流量值不变。

#### 分钟归档

```text
windowStart = reportedAt - reportedAt % 60
```

同一账户、Tunnel 和分钟内的原始计量合并为一条分钟用量。

#### 月度账期

```text
periodStart = UTC 当月 1 日 00:00:00
periodEnd   = UTC 下月 1 日 00:00:00
```

流量按 `reportedAt` 所在月份结算。进入新月份时创建新账期，不清空或覆盖旧账期。

#### 余额计算

```text
remainingBytes = max(0, quotaBytes - billedBytes)
```

`billedBytes` 只包含已结算数据，允许与 Gateway 实时流量存在约一分钟差异。

#### 结算一致性

- 原始记录、分钟用量和月度用量在同一结算事务内处理；
- 只有聚合结果全部成功后，原始记录才变为已结算；
- 失败后原始记录保持可重试；
- 多实例处理时，每条原始记录只允许一个实例完成结算。

### 3.4 关键代码

本节只列出业务入口，具体实现以代码为准。

| 类 | 业务职责 |
| --- | --- |
| `BillingService` | 账户、套餐、账期和余额 |
| `BillingSettlementJob` | 每分钟启动结算 |
| `BillingSettlementService` | 计量聚合、入账和完成标记 |
| `LimitsAppService` | 限制与余额响应 |
| `TunnelAppService` | Tunnel 配额、Token 额度校验、状态查询 |
| `TunnelPortAppService` | Port 配额 |
| `TunnelCleanupJob` | 过期 Tunnel 和陈旧状态清理 |

关键处理顺序：

```text
读取未结算计量
  -> 按分钟合并
  -> 累计月度与分钟用量
  -> 标记原始计量已结算
```

### 3.5 接口定义

接口统一前缀：

```text
/open-api-inner/v1/relay-controller
```

只列出二期新增或行为发生变化的接口：

| 方法与路径 | 二期变化 | 主要响应或错误 |
| --- | --- | --- |
| `GET /limits` | 新增限制与月度余额查询 | 返回额度、余额、重置时间和套餐限制 |
| `GET /tunnels/{tunnelId}` | 详情新增可选 `status` | 返回连接数、实时速率和状态时间 |
| `POST /tunnels` | 增加账户绑定、账户状态和 Tunnel 配额校验 | 超过套餐上限时返回配额错误 |
| `POST /tunnels/{tunnelId}/ports` | 增加 Port 配额校验 | 超过单 Tunnel 上限时返回配额错误 |
| `POST /tunnels/{tunnelId}/token` | 增加账户状态和月度额度校验 | 禁用或超额时拒绝签发 |

`GET /limits` 关键返回字段：

| 字段 | 含义 |
| --- | --- |
| `resetAt` | 当前 UTC 月度账期结束时间，Unix 秒 |
| `quotaBytes` | 本月总额度 |
| `remainingBytes` | 已结算口径的剩余额度 |
| `activeTunnels` / `maxTunnels` | 当前有效 Tunnel 数量及上限 |
| `maxPortsPerTunnel` | 单 Tunnel Port 上限 |
| `maxHostsPerTunnel` | 单 Tunnel Host 上限 |
| `maxTunnelBandwidthBytesPerSecond` | 单 Tunnel 带宽上限 |
| `maxHttpRequestsPerMinutePerPort` | 单 Port HTTP 请求上限 |
| `maxConnectionsPerPort` | 单 Port 并发连接上限 |

Tunnel 详情新增 `status`：

| 字段 | 含义 |
| --- | --- |
| `hostConnectionCount` | 当前 Host 连接数 |
| `clientConnectionCount` | 当前活动 SSH Channel 数 |
| `uploadBytesPerSecond` | 当前上传速率 |
| `downloadBytesPerSecond` | 当前下载速率 |
| `reportedAt` | Gateway 最近状态时间，Unix 秒 |

Gateway 与 Controller 的数据库协作契约：

| 数据 | Gateway 行为 | Controller 行为 |
| --- | --- | --- |
| 原始计量 | 每 30 秒和会话结束时写入增量 | 每分钟结算 |
| 运行状态 | 按 Tunnel 保存最新状态 | 在 Tunnel 详情中读取 |
| 月度额度 | 连接建立和运行时读取 | 生成并更新账期 |

Relay Controller 不新增 `/metering` 或 `/tunnels/status`。HTTP 请求和响应以 OpenAPI YAML 为最终契约。

### 3.6 数据表设计

#### 表关系

```text
namespace
   |
billing_account --> billing_plan
   |
   +--> tunnel --> tunnel_runtime_status
   |
   +--> tunnel_metering --> billing_usage_1m
   |
   +--> billing_period
```

#### 二期新增及变更表

| 表 | 用途 | 关键字段 | 数据生命周期 |
| --- | --- | --- | --- |
| `billing_plan` | 套餐和限制的统一来源 | `plan_code` 及各项限制 | 长期保留 |
| `billing_account` | `namespace` 与套餐绑定 | `_id`、`namespace`、`plan_code`、`status` | 长期保留 |
| `billing_period` | UTC 月度额度与已结算流量 | `account_id`、起止时间、额度、已用流量 | 长期保留 |
| `tunnel_metering` | Gateway 原始增量计量 | 归属、会话、流量、上报时间、结算状态 | 已结算数据保留 7 天 |
| `billing_usage_1m` | Tunnel 分钟用量 | 账户、Tunnel、分钟、流量 | 长期保留 |
| `tunnel_runtime_status` | Tunnel 最新运行状态 | 连接数、速率、上报时间 | 覆盖更新，陈旧数据清理 |
| `tunnel` | 增加账户归属 | 新增 `account_id` | 延续一期生命周期 |

#### 唯一性与查询要求

- `billing_account.namespace` 唯一，保证一个 Namespace 只对应一个账户；
- `billing_period(account_id, period_start)` 唯一，保证一个账户每月只有一个账期；
- `tunnel_metering(tunnel_id, session_id, reported_at)` 唯一，保证上报重试幂等；
- `billing_usage_1m(account_id, tunnel_id, window_start)` 唯一，保证分钟结果可持续累计；
- `tunnel_runtime_status.tunnel_id` 唯一，只保存每个 Tunnel 的最新状态；
- 未结算计量、账户时间范围和陈旧状态需要对应索引支持。

历史一期 `metering` 表由二期迁移删除，避免两套计量口径同时存在。

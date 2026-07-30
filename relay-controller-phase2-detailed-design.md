# Relay Controller 二期详细设计

本文描述 Relay Controller 二期的业务范围、实现方案及接口和数据契约，供 SE、测试及关联服务开发对齐。

## 1 价值描述

### 作为

作为 DevBridge 隧道服务的用户。

### 我要

我要查看账户限制和月度流量余额，并由系统自动管理资源配额、流量结算和 Tunnel 运行状态。

### 从而

- 使用资源前能够了解限制和余额；
- 超出限制时得到明确、一致的处理结果；
- Tunnel 的用量和运行情况可查询、可追溯。

### 现状

一期已具备 Tunnel、Port 和 Token 管理能力，但缺少账户套餐、流量结算、余额查询和运行状态，尚未形成资源使用闭环。

### 要求

二期需要补齐“账户与套餐、资源配额、流量结算、余额查询、状态展示”闭环，并保证多 Region、多副本运行时数据不重不漏。

## 2 功能描述

### 2.1 功能说明

| 功能 | 说明 |
| --- | --- |
| 账户与套餐 | 一个 `namespace` 对应一个账户；首次使用时自动创建并绑定默认 `trial` 套餐 |
| 资源配额 | 创建 Tunnel、Port 时校验套餐限制；过期或已删除 Tunnel 不占用有效 Tunnel 配额 |
| 流量结算 | Gateway 写入增量流量，Controller 生成分钟用量和月度累计用量 |
| 限制与余额 | 返回本月额度、剩余额度、重置时间和资源限制 |
| 运行状态 | Tunnel 详情返回 Gateway 最近上报的连接数、速率和上报时间 |
| Token 校验 | 签发前校验账户状态和月度额度；Token 有效期使用固定配置 |

默认 `trial` 套餐：

| 项目 | 规格 |
| --- | ---: |
| 月度流量 | 5 GiB |
| 有效 Tunnel | 10 个/账户 |
| Port | 10 个/Tunnel |
| Host 连接 | 1 个/Tunnel |
| 带宽 | 5 MiB/s/Tunnel |
| HTTP 请求 | 500 次/分钟/Port |
| 并发连接 | 100 个/Port |

计量和结算周期：

- Gateway 每 30 秒写入一次增量流量，并在 Host 会话结束时补充写入；
- Controller 每分钟结算一次；
- 余额按已结算流量计算，正常情况下允许约一分钟延迟；
- 月度额度按 UTC 自然月生成新账期，不修改历史账期。

### 2.2 约束与依赖

#### 职责边界

| 组件 | 本期职责 |
| --- | --- |
| Relay Controller | 账户、套餐、资源配额、结算、余额、Token 校验和状态展示 |
| Relay Gateway | Host 侧流量统计、计量与状态写库，以及 Host、带宽、HTTP、连接和超额控制 |
| CLI | Echo、Ping、随机端口和本地 HTTP Server，不属于本项目 |

#### 运行依赖

- Controller 与 Gateway 共用 MySQL/MariaDB；
- Cluster 需提前创建并绑定 Region；
- Controller 只处理本 Region 所属 Cluster 的数据；
- 时间统一使用 Unix 秒，账期和分钟窗口使用 UTC；
- Gateway 从 `tunnel` 表取得 `account_id` 和 `cluster_id`，外部输入不能决定计量归属；
- Controller 不提供计量或状态上报 HTTP 接口；
- 原始计量按 `reported_at` 小时分区；Controller 只删除超过 7 天且没有未结算数据的分区。

#### 安全边界

- mTLS 确认服务身份，可信入口仍需校验并传递 `X-Namespace`；
- JWT 的 `aud` 为 `relay-gateway`，Gateway 校验签名、有效期、Audience、Tunnel、Cluster 和 Scope；
- `forCookies=true` 仅标识交付方式，当前 Token 仍为可读取 Claims 的签名 JWT；
- Cookie 写入和 JWE 加密不在本次交付范围。

## 3 实现设计

### 3.1 总体设计描述

```text
Host 流量
   |
Relay Gateway
   |-- 增量流量 --> tunnel_metering
   |-- 最新状态 --> tunnel_runtime_status
                         |
                  Relay Controller
                    周期结算
                         |
              +----------+----------+
              v                     v
      billing_usage_1m       billing_period
                                      |
                              Limits / Token 校验
```

设计采用三层数据：

1. `tunnel_metering` 保存 Gateway 原始增量，作为结算输入和短期核查依据；
2. `billing_usage_1m` 保存 Tunnel 分钟用量，支持问题定位和用量分析；
3. `billing_period` 保存账户月度累计，作为余额和额度判断依据。

运行状态独立保存在 `tunnel_runtime_status`，不参与计费。

### 3.2 业务流程

| 流程 | 触发 | 核心处理 | 结果 |
| --- | --- | --- | --- |
| 创建 Tunnel | 用户创建 Tunnel | 创建或读取账户，校验状态和有效 Tunnel 数量 | 成功创建并绑定账户，或返回配额错误 |
| 创建 Port | 用户创建 Port | 校验 Tunnel 和当前 Port 数量 | 成功创建，或返回配额错误 |
| 写入计量 | Gateway 周期上报或 Host 会话结束 | 写入本周期增量，重复请求保持幂等 | 形成待结算原始记录 |
| 分钟结算 | Controller 定时任务 | 按账户、Tunnel、分钟聚合并累计月度用量 | 原始记录变为已结算 |
| 查询余额 | 用户查询 Limits 或申请 Token | 读取当前 UTC 账期和套餐 | 返回余额，或在超额时拒绝 Token |
| 查询状态 | 用户查询 Tunnel 详情 | 读取 Gateway 最新状态 | 有状态则返回，无状态则仅返回 Tunnel |

### 3.3 关键业务算法

#### 计量幂等

```text
唯一标识 = tunnelId + sessionId + reportedAt
```

`usageBytes` 表示自上次成功上报后的新增流量。重试同一次上报时，唯一标识和流量值必须保持不变。

#### 时间归档

```text
windowStart = reportedAt - reportedAt % 60
periodStart = UTC 当月 1 日 00:00:00
periodEnd   = UTC 下月 1 日 00:00:00
```

计量按 `reportedAt` 归入分钟和月份，避免延迟到达的数据进入错误账期。

#### 余额

```text
remainingBytes = max(0, quotaBytes - billedBytes)
```

账期创建时保存套餐额度快照，后续套餐调整不改变历史账期。

#### 一致性

- 聚合结果和原始记录结算状态在同一事务内完成；
- 失败时整体回滚，下一周期继续处理；
- 多实例可并行处理，但每条原始记录只能完成一次结算；
- 资源数量校验与创建作为一个完整业务操作，避免并发突破配额。

### 3.4 关键代码

本节仅列业务入口，具体实现以代码为准。

| 类 | 职责 |
| --- | --- |
| `BillingService` | 账户、套餐、账期和余额 |
| `BillingSettlementJob` | 周期触发结算 |
| `BillingSettlementService` | 聚合计量并更新结算结果 |
| `MeteringPartitionJob` | 创建和回收原始计量小时分区 |
| `LimitsAppService` | 组装限制与余额 |
| `TunnelAppService` | Tunnel 配额、Token 校验和状态查询 |
| `TunnelPortAppService` | Port 配额 |
| `TunnelCleanupJob` | 清理过期 Tunnel 及其 Port 和运行状态 |

### 3.5 接口定义

接口前缀：

```text
/open-api-inner/v1/relay-controller
```

仅列二期新增或有行为变化的接口：

| 方法与路径 | 二期变化 |
| --- | --- |
| `GET /limits` | 新增限制和月度余额查询 |
| `GET /tunnels/{tunnelId}` | 响应新增可选 `status` |
| `POST /tunnels` | 增加账户状态和 Tunnel 配额校验 |
| `POST /tunnels/{tunnelId}/ports` | 增加 Port 配额校验 |
| `POST /tunnels/{tunnelId}/token` | 增加账户状态和月度额度校验 |

`GET /limits` 返回：

| 字段 | 含义 |
| --- | --- |
| `resetAt` | 当前账期结束时间 |
| `quotaBytes` / `remainingBytes` | 月度总额度和剩余额度 |
| `activeTunnels` / `maxTunnels` | 有效 Tunnel 数量和上限 |
| `maxPortsPerTunnel` | Port 上限 |
| `maxHostsPerTunnel` | Host 上限 |
| `maxTunnelBandwidthBytesPerSecond` | Tunnel 带宽上限 |
| `maxHttpRequestsPerMinutePerPort` | Port HTTP 请求上限 |
| `maxConnectionsPerPort` | Port 并发连接上限 |

Tunnel 详情新增 `status`：

| 字段 | 含义 |
| --- | --- |
| `hostConnectionCount` | Host 连接数 |
| `clientConnectionCount` | 活动 SSH Channel 数 |
| `uploadBytesPerSecond` / `downloadBytesPerSecond` | 当前上下行速率 |
| `reportedAt` | Gateway 状态时间 |

Gateway 数据协作契约：

| 数据 | Gateway | Controller |
| --- | --- | --- |
| 原始计量 | 写入增量 | 读取并结算 |
| 运行状态 | 保存最新值 | 在 Tunnel 详情中读取 |
| 月度账期 | 读取额度用于数据面控制 | 创建并累计用量 |

Controller 不新增 `/metering` 或 `/tunnels/status`。HTTP 契约以 OpenAPI YAML 为准。

### 3.6 数据表设计

| 表 | 用途 | 关键约束 | 生命周期 |
| --- | --- | --- | --- |
| `billing_plan` | 套餐和限制 | `plan_code` 唯一 | 长期保留 |
| `billing_account` | `namespace` 与套餐绑定 | `namespace` 唯一 | 长期保留 |
| `billing_period` | 月度额度和累计用量 | 账户与月份唯一 | 长期保留 |
| `tunnel_metering` | 原始增量计量 | 按上报时间小时分区；Tunnel、会话与上报时间唯一 | 已结算数据保留 7 天 |
| `billing_usage_1m` | Tunnel 分钟用量 | 账户、Tunnel 与分钟唯一 | 长期保留 |
| `tunnel_runtime_status` | Tunnel 最新状态 | `tunnel_id` 唯一 | 覆盖更新，随 Tunnel 删除 |
| `tunnel` | 增加账户归属 | 新增 `account_id` 及索引 | 延续一期生命周期 |

`tunnel_metering` 核心字段：

| 字段 | 含义 |
| --- | --- |
| `account_id` / `cluster_id` / `tunnel_id` | 计量归属 |
| `session_id` | Host 会话 |
| `usage_bytes` | 本次新增流量 |
| `reported_at` / `created_at` | Gateway 上报时间和入库时间 |
| `settled` | 是否已完成结算 |

Controller 每小时预建未来 2 小时分区，并保留 `p_future` 接收边界外数据。多副本通过数据库锁串行维护；超过 7 天的分区只有在全部结算后才会被删除。

历史一期 `metering` 表由二期迁移删除，避免两套计量口径并存。

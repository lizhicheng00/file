# DevBox 沙箱生命周期增强详细设计 Story

本文描述 DevBox Manager 与 Python、JavaScript SDK 的沙箱生命周期增强。Manager 是跨 region、跨集群的全局控制面；快照生成、虚拟机暂停和恢复由沙箱所在节点执行。

## 1 价值描述

### 作为

作为通过 Python 或 JavaScript SDK 使用 DevBox 的开发者。

### 我要

我要暂停和恢复沙箱、调整剩余运行时间，并为到期沙箱选择销毁或自动暂停策略。

### 从而

从而在保留文件、内存和进程现场的同时减少空闲资源占用，并能明确控制沙箱的可用时间和资源成本。

### 现状

沙箱创建后持续运行到超时或主动删除。用户暂时离开时无法保留现场，重新创建会丢失运行状态；创建、连接和续期对 timeout 的处理也缺少统一语义。

### 要求

- 暂停和恢复不改变 sandbox ID，恢复后可以继续使用原有现场。
- 支持手动暂停、显式恢复、连接时恢复和 Gateway 流量唤醒。
- 支持超时销毁和超时自动暂停两种策略。
- timeout 可以缩短或延长生命周期，refresh 只能延长。
- 到期和删除最终完成节点、Tunnel、快照、配额与状态回收。
- Python 同步、Python 异步和 JavaScript SDK 保持相同业务语义。

## 2 功能描述

### 2.1 功能说明

本次新增能力分为三组：沙箱暂停与恢复、生命周期时间调整、到期处理。

#### 状态与操作

| 当前状态 | pause | resume | connect | timeout / refresh | delete |
|---|---|---|---|---|---|
| running | 暂停并保存现场 | 状态冲突 | 返回连接信息 | 调整截止时间 | 销毁 |
| paused | 幂等成功 | 从快照恢复 | 恢复后返回连接信息 | 不允许 | 销毁并清理快照 |
| 处理中 | 状态冲突 | 状态冲突 | 状态冲突 | 状态冲突 | 按删除流程收敛 |
| killed / 不存在 | 不存在 | 不存在 | 不存在 | 不存在 | 已销毁返回冲突，不存在返回 404 |

暂停保留同一 sandbox ID、文件系统、内存和进程现场。一个暂停沙箱只保留一份有效恢复快照；恢复、删除或暂停保留期结束后清理该快照。

恢复回到原节点，续期原 Relay tunnel，并签发新的连接凭证。SDK 用新连接信息替换本地旧连接。

#### 生命周期策略

| 配置 | 含义 |
|---|---|
| onTimeout=kill | 到期销毁，默认策略 |
| onTimeout=pause | 到期保存完整快照并暂停 |
| autoResume=true | 允许 Gateway 流量唤醒，仅与 pause 组合使用 |

未开启 auto resume 时，暂停沙箱需要先调用 resume() 或 connect()。开启后，Gateway 根据 tunnel ID 调用 Manager 内部接口完成恢复，并重试原数据面请求；SDK 不参与这次恢复编排。

#### 时间语义

生命周期统一使用秒，最大值为 86400 秒。

| 操作 | 语义 |
|---|---|
| 创建、恢复 | 设置本次运行的截止时间；显式正数最少为 10 秒 |
| set_timeout(x) | 截止时间改为“当前时间 + x”，可以缩短或延长 |
| refresh(x) | 截止时间改为 max(原截止时间, 当前时间 + x)，只能延长 |
| running 状态 connect(timeout=x) | 使用 refresh 语义 |
| set_timeout(0) | 立即到期，由后台任务回收 |
| refresh(0) | 使用服务默认时长，不表示立即到期 |

到期判断以 Manager 保存的截止时间为准。节点停止和控制面状态更新存在短暂收敛时间，但到期后不能通过 connect、refresh 或 set timeout 重新激活沙箱。

暂停不会冻结原运行剩余时间。假设创建时 timeout 为 X，运行 A 后暂停，并保持暂停 Y：暂停后原来的 X-A 不再使用，沙箱获得 24 小时暂停保留期；只要 Y 小于 24 小时，恢复时再从当前时刻获得本次请求指定的 R 秒运行时间。SDK 未传恢复时间时 R 默认为 300 秒，Gateway 自动唤醒时使用 Manager 默认时长。暂停超过 24 小时则不能恢复。

running 沙箱 connect 时返回当前连接凭证；paused 沙箱恢复时，Manager 会续期 Tunnel 并签发新的 connect token，SDK 随响应替换旧凭证。

### 2.2 约束与依赖

- 节点需要支持完整内存、文件系统快照以及从快照恢复。
- 快照保存在原节点，当前不支持跨节点恢复；原节点不可用时返回服务不可用。
- 暂停状态默认保留 24 小时，超过保留期后销毁。
- MySQL 保存权威状态；Redis 保存运行视图、到期索引和配额计数。
- 恢复需要 Relay 续期同一 tunnel 并签发新 token，tunnel ID 不允许变化。
- 多 Manager 实例通过数据库状态协调同一沙箱的并发生命周期操作。
- Gateway 自动唤醒接口只在独立 mTLS 端口开放，不经过公网 API Key 鉴权。
- Gateway 在恢复成功后负责重试原请求，旧 connect token 需要覆盖本次唤醒过程。
- 节点快照物理文件的最终清理由下层能力保证。
- 仅文件系统快照暂不开放。

## 3 实现设计

### 3.1 总体设计描述

| 组件 | 职责 |
|---|---|
| SDK | 提供生命周期接口，更新 Sandbox 对象并关闭失效的数据面连接 |
| Gateway | 识别暂停 tunnel，调用 Manager 自动唤醒接口，恢复后重试数据面请求 |
| Manager | 校验状态并编排快照、恢复、配额、Tunnel、持久化和到期回收 |
| 节点运行时 | 保存和恢复沙箱现场，执行暂停、恢复与销毁 |

MySQL 是跨 Manager 实例的权威来源。Redis 只用于加速连接、配额和到期扫描；Redis 缺失或数据过期时，Manager 仍以 MySQL 完成查询和收敛。

~~~text
                    pause / timeout=pause
              +----------------------------+
              |                            v
created -> running <--------------------- paused
              |       resume / connect      |
              |                              | retention expired
              +-----------> killed <---------+
                 timeout=kill / delete
~~~

pausing、snapshotting、killing 等处理中状态只用于拒绝冲突操作，不作为长期状态。

### 3.2 业务流程

#### 3.2.1 暂停与恢复

暂停：

1. SDK 请求暂停 running 沙箱。
2. Manager 锁定沙箱记录，确认状态后生成 snapshot ID，并保存恢复配置。
3. 原节点保存内存和文件系统快照并停止实例。
4. 节点确认成功后，Manager 将状态改为 paused，设置 24 小时保留期并释放运行配额。
5. SDK 更新本地状态并关闭旧数据面连接。

恢复：

1. 用户调用 resume()，或对 paused 沙箱调用 connect()。
2. Manager 锁定沙箱记录，确认快照、原节点和运行配额均可用。
3. Manager 续期同一 Relay tunnel，并获取新的连接凭证。
4. 原节点使用快照恢复同一 sandbox ID。
5. Manager 将状态改为 running，更新运行时间、截止时间和连接信息，删除已消费的快照记录。
6. SDK 使用新的 token 和访问地址替换旧连接。

暂停请求对已 paused 沙箱幂等。恢复结果不明确时，Manager 先确认上次操作结果，不直接创建第二个实例。

对外业务动作始终是 resume。Manager 调用节点 Create RPC，是因为暂停时原虚拟机已经停止，节点通过“按快照创建运行实例”完成恢复；它不是新建一个业务沙箱，sandbox ID、快照归属和 Tunnel 关系均沿用原记录。

#### 3.2.2 自动暂停与自动唤醒

到期扫描发现 running 沙箱采用 pause 策略时，复用暂停流程。执行前重新核对状态、策略和截止时间，避免刚续期的沙箱被旧扫描结果暂停。

暂停后保留 tunnel ID。Gateway 收到该 tunnel 的命令、文件、PTY 或代理请求时：

1. Gateway 使用客户端证书向 Manager 独立端口提交 tunnel ID。
2. Manager 找到沙箱，确认其处于 paused、未超过保留期且允许 auto resume。
3. Manager 在数据库状态保护下复用恢复流程；并发唤醒只执行一次实际恢复。
4. Manager 返回成功后，Gateway 重试原数据面请求。

auto pause 不会让沙箱永久保留。没有恢复操作时，paused 沙箱在 24 小时保留期结束后被销毁；有流量唤醒时进入新的运行周期，后续到期可再次暂停。用户也可以在任意阶段主动 delete。

#### 3.2.3 截止时间调整

1. Manager 校验沙箱属于调用 namespace、处于 running 且尚未到期。
2. 按 timeout 或 refresh 语义计算新截止时间。
3. 更新 MySQL、Redis 到期索引和节点停止时间。
4. 必要时异步延长 Relay tunnel，使其有效期覆盖沙箱生命周期。

对于 0 至 5 秒的短时限，不向节点发送可能因网络耗时而失效的更新，交由 Manager 到期任务回收。

#### 3.2.4 到期回收

1. Manager 每 30 秒合并 Redis 到期索引和 MySQL 到期记录。
2. 对候选记录加锁并重新确认状态和截止时间。
3. running 且采用 pause 策略的沙箱进入暂停流程；其余到期沙箱进入销毁流程。
4. 销毁流程停止节点实例、删除 Relay tunnel 和 Redis 运行数据，将数据库状态更新为 killed，并清理快照和运行配额。
5. 节点清理失败时不提前写入 killed，保留数据供下一轮重试。

### 3.3 关键业务算法

#### 截止时间

~~~text
set timeout: newEnd = now + timeout
refresh:     newEnd = max(oldEnd, now + duration)
connect:     running 时使用 refresh；paused 时使用恢复时长
~~~

timeout 允许主动缩短成本窗口；refresh 和 running connect 不会意外缩短现有生命周期。

#### 并发与幂等

pause、resume、connect、delete、timeout、refresh 和后台回收均以 MySQL 当前状态为准。状态修改前重新确认记录，避免续期与回收、暂停与删除、多实例恢复以及超时重试之间发生冲突。

重复请求只在状态已经达到目标时幂等成功；与当前状态冲突的请求返回 409。

#### 快照与 Tunnel 一致性

暂停快照绑定 sandbox ID、namespace、原节点和 snapshot ID。恢复只消费当前沙箱的有效快照；快照缺失、归属不符或原节点不可用时不创建替代沙箱。

Gateway 使用 tunnel ID 定位暂停沙箱，因此恢复必须维持原 tunnel ID。Relay 返回不同 tunnel ID 时，本次恢复失败，避免原请求被路由到错误实例。

### 3.4 关键代码

Manager：

| 文件 | 作用 |
|---|---|
| internal/handlers/sandbox_pause.go | 手动与自动暂停、快照记录 |
| internal/handlers/sandbox_resume.go | 显式恢复、Gateway 自动唤醒、配额和连接更新 |
| internal/handlers/sandbox_connect.go | running 连接与 paused 恢复 |
| internal/handlers/sandbox_lifecycle.go | timeout、refresh 和生命周期共用逻辑 |
| internal/orchestrator/orchestrator.go | 节点操作、到期扫描与回收 |
| cmd/internal_server.go | Gateway 独立 mTLS 接口 |

SDK：

| 文件 | 作用 |
|---|---|
| python-sdk/src/devbox/sandbox.py | Python 同步和异步生命周期接口 |
| js-sdk/src/sandbox.ts | JavaScript 生命周期接口 |
| python-sdk/examples/validate_lifecycle.py | Python 生命周期联调入口 |
| js-sdk/examples/validate-lifecycle.mjs | JavaScript 生命周期联调入口 |

### 3.5 接口定义

#### Manager API

| 方法 | 路径 | 请求 | 成功响应 | 说明 |
|---|---|---|---|---|
| POST | /sandboxes/{sandboxID}/pause | { "memory": true }，可省略 | 204 | 保存完整快照并暂停 |
| POST | /sandboxes/{sandboxID}/resume | { "timeout": 300 }，可省略 | 201 + Sandbox | 显式恢复并返回新连接信息 |
| POST | /sandboxes/{sandboxID}/connect | { "timeout": 300 }，可省略 | 200 或 201 + Sandbox | 连接 running 沙箱或恢复 paused 沙箱 |
| POST | /sandboxes/{sandboxID}/timeout | { "timeout": 7200 } | 204 | 覆盖剩余生命周期 |
| POST | /sandboxes/{sandboxID}/refreshes | { "duration": 7200 } | 204 | 只延长剩余生命周期 |

#### Gateway 内部 API

该接口只监听 INTERNAL_PORT，校验 Gateway 客户端证书，不在公开 API 端口注册。

| 方法 | 路径 | 成功响应 | 说明 |
|---|---|---|---|
| POST | /open-api-inner/v1/devbox-manager/tunnels/{tunnelId}/resume | 204 | running 时幂等成功；paused 时按策略恢复 |

主要错误语义：

| HTTP 状态 | 场景 |
|---|---|
| 400 | 参数格式、时间范围或生命周期组合错误 |
| 404 | 沙箱不存在、已到期或暂停快照不存在 |
| 409 | 当前状态不允许、配额不足或前一次操作尚未收敛 |
| 503 | 保存快照的原节点暂时不可用 |
| 500 | 快照、恢复或持久化过程发生内部错误 |

#### SDK API

~~~python
sandbox = Sandbox.create(
    lifecycle=SandboxLifecycle(on_timeout="pause", auto_resume=True)
)
sandbox.pause()
sandbox.resume(timeout=300)
Sandbox.connect(sandbox_id, timeout=300)
sandbox.set_timeout(7200)
sandbox.refresh(7200)
~~~

~~~javascript
const sandbox = await Sandbox.create({
  lifecycle: { onTimeout: "pause", autoResume: true }
})
await sandbox.pause()
await sandbox.resume({ timeout: 300 })
await Sandbox.connect(sandboxId, { timeout: 300 })
await sandbox.setTimeout(7200)
await sandbox.refresh(7200)
~~~

pause() 关闭当前 SDK 数据面连接；resume() 更新当前 Sandbox 对象；connect() 返回可用的 Sandbox 对象。close() 只关闭本地连接，kill() 才删除远端沙箱。

### 3.6 数据表设计

#### t_sandbox 生命周期字段

| 字段 | 说明 |
|---|---|
| sandbox_id | 沙箱唯一标识，暂停恢复期间不变 |
| namespace | 用户隔离范围 |
| status | running、paused、killed 等状态 |
| node_id | 沙箱和本地快照所在节点 |
| start_time | 本次运行开始时间，恢复后更新 |
| end_time | 当前状态的截止时间 |
| actual_end_time | 实际终止时间 |
| tunnel_id | 稳定的 Relay tunnel 标识，也是自动唤醒查询条件 |
| auto_pause | 到期时暂停而不是销毁 |
| auto_resume | 是否允许 Gateway 流量唤醒 |
| connect_token | 加密保存的数据面连接凭证 |
| token_expiration | connect token 过期时间 |
| tunnel_expiration | tunnel 过期时间 |

#### t_snapshot

| 字段 | 说明 |
|---|---|
| snapshot_id | 单次暂停快照标识 |
| sandbox_id | 所属沙箱 |
| namespace | 所属隔离范围 |
| template_id | 沙箱模板标识 |
| config | 恢复所需配置 |
| is_paused | 是否为暂停恢复快照 |
| origin_node_id | 保存快照的原节点 |
| created_at | 快照创建时间 |

暂停快照以 (sandbox_id, namespace, is_paused) 查询。恢复和删除按 snapshot ID 或 sandbox ID 清理记录，沙箱状态始终以 t_sandbox 为准。t_sandbox.tunnel_id 建立索引，供 Gateway 唤醒入口定位沙箱。

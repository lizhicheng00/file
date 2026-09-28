# DevBox 沙箱生命周期增强详细设计 Story

本文描述 DevBox Manager 与 Python/JavaScript SDK 负责的沙箱生命周期增强。Manager 是跨 region、跨集群部署的全局控制面；沙箱运行时、快照文件和虚拟机恢复由下层节点执行。

## 1 价值描述

### 作为

作为通过 Python 或 JavaScript SDK 使用 DevBox 的开发者。

### 我要

我要暂停暂时不用的沙箱，并在需要时恢复同一沙箱；也要能够调整沙箱剩余运行时间，并在沙箱到期后自动释放资源。

### 从而

从而在保留文件、内存和进程现场的同时减少空闲资源占用，并通过明确的生命周期接口控制沙箱成本和可用时间。

### 现状

沙箱创建后持续运行到超时或主动删除。用户离开后无法保留现场，重新创建会丢失运行状态；不同接口对 timeout 的限制和语义也需要统一。

### 要求

- 暂停后保留沙箱 ID、文件、内存和进程现场。
- 恢复后继续使用同一沙箱，并获得新的数据面连接凭证。
- `connect` 遇到暂停沙箱时完成恢复，保持与 E2B 接近的使用方式。
- 创建时可以选择超时销毁或超时自动暂停。
- 开启 auto resume 后，Gateway 收到数据面请求时可以按 tunnel ID 自动唤醒暂停沙箱。
- timeout 可以缩短或延长沙箱生命周期，refresh 只能延长。
- 到期沙箱不能通过续期接口重新激活，并最终完成节点、隧道和状态回收。
- Python 同步/异步 SDK 与 JavaScript SDK 保持一致的业务语义。

## 2 功能描述

### 2.1 功能说明

#### 手动暂停

运行中的沙箱可以执行 `pause`。Manager 为本次暂停生成唯一快照标识，通知沙箱所在节点保存完整的内存和文件系统快照；快照确认成功后，将沙箱状态更新为 `paused` 并释放运行配额。

暂停快照属于沙箱生命周期内部资源，一个暂停沙箱只使用一份有效恢复快照。沙箱恢复、删除或超过暂停保留时间后，该快照记录随沙箱状态一起清理。

#### 恢复与连接

暂停沙箱可以通过 `resume` 显式恢复，也可以通过 `connect` 恢复。恢复使用原节点上的暂停快照，保持原 sandbox ID，并重新申请运行配额、续期既有 Relay tunnel 和签发连接凭证。

`connect` 的行为取决于沙箱状态：

| 状态 | 行为 |
|---|---|
| `running` | 返回连接信息；传入 timeout 时只延长生命周期 |
| `paused` | 从快照恢复，返回新的连接信息 |
| `pausing`、`killing`、`snapshotting` | 返回状态冲突 |
| `killed`、不存在或已经到期 | 返回不存在 |

未开启 auto resume 时，暂停状态下的数据面操作会提示用户先调用 `resume()` 或 `connect()`。开启后，SDK 直接向 Gateway 发送原请求；Gateway 根据请求中的 tunnel ID 调用 Manager 内部恢复接口，恢复成功后重试原请求。SDK 不额外调用 Manager，也不管理恢复并发。

#### 超时自动暂停与流量唤醒

创建沙箱时可设置生命周期策略：

- `onTimeout=kill`：到期后销毁，为默认行为。
- `onTimeout=pause`：到期后生成内存快照并暂停，保留 24 小时。
- `autoResume=true`：仅能与 `onTimeout=pause` 组合，允许 Gateway 流量唤醒。

Gateway 只持有 tunnel ID，不需要用户 API Key 或 namespace。Manager 通过 `t_sandbox.tunnel_id` 找到沙箱及其 namespace，在数据库行锁内完成恢复。并发唤醒同一 tunnel 时只执行一次恢复，其余请求在确认沙箱已运行后按成功处理。

#### 生命周期调整

生命周期统一使用秒，最大值为 86400 秒。创建和恢复需要为节点预留启动时间，显式正数最少为 10 秒。

- `set_timeout(x)`：将截止时间重设为 `当前时间 + x`，可以缩短或延长。
- `refresh(x)`：将截止时间更新为 `max(原截止时间, 当前时间 + x)`，只能延长。
- running 状态下的 `connect(timeout=x)`：使用 refresh 语义，只延长。
- `set_timeout(0)`：立即到期，随后由后台任务回收。
- `refresh(0)`：使用服务默认生命周期，不表示立即到期。

#### 到期回收

节点按沙箱截止时间停止运行实例。Manager 每 30 秒扫描一次 Redis 到期索引和 MySQL 到期记录，对候选数据重新确认状态和截止时间后执行回收：

- 删除或确认节点实例已不存在；
- 删除 Relay tunnel；
- 删除 Redis 运行状态；
- 将数据库状态更新为 `killed`；
- 清理暂停快照记录；
- 释放运行配额。

节点停止与 Manager 状态落库不是同一时刻，因此到期状态允许短暂收敛延迟。截止时间一旦到达，`connect`、`refresh` 和 `set_timeout` 均不能让沙箱复活。

### 2.2 约束与依赖

- 暂停和恢复依赖节点提供完整内存、磁盘快照及快照启动能力。
- 快照当前保存在原节点，恢复必须回到原节点；原节点不可用时返回服务不可用，不能跨节点恢复。
- 暂停状态默认保留 24 小时，到期后沙箱进入终态。
- Manager 依赖 MySQL 保存权威状态，Redis 保存运行视图、到期索引和配额计数。
- 恢复依赖 Relay 续期同一 tunnel 并签发新 token；自动唤醒时 tunnel ID 不允许变化。
- 多 Manager 实例通过数据库状态串行化同一沙箱的生命周期操作，后台回收任务使用分布式调度锁。
- 节点快照物理文件的删除依赖下层提供清理能力；Manager 删除快照记录不等同于已经删除节点文件。
- Gateway 到 Manager 的唤醒接口仅在独立 mTLS 端口开放，不经过公网 API Key 鉴权链路。
- Gateway 需要在 Manager 返回成功后重试原数据面请求；旧 connect token 在该次请求重试期间必须仍然有效。
- 仅文件系统快照暂不开放。

## 3 实现设计

### 3.1 总体设计描述

生命周期由三个部分协作完成：

| 组件 | 职责 |
|---|---|
| SDK | 提供 pause、resume、connect、set timeout、refresh；维护本地状态并关闭失效的数据面连接 |
| Gateway | 识别暂停 tunnel，通过 mTLS 调用 Manager，恢复后重试原数据面请求 |
| Manager | 作为全局控制面校验状态，编排快照、恢复、配额、Tunnel 和持久化，执行到期回收 |
| 节点运行时 | 生成内存与文件系统快照，从快照恢复实例，按截止时间停止实例 |

MySQL 是跨实例的权威状态。Redis 用于快速连接视图、运行数量和到期扫描，但 Redis 数据缺失时，Manager 仍通过 MySQL 完成查询与回收。

生命周期主状态如下：

```text
             pause / timeout policy
    running -----------------> paused
       |                         |
       | timeout/delete          | resume/connect
       v                         v
     killed <----------------- running
       ^
       |
       +------ paused retention expired
```

### 3.2 业务流程

#### 3.2.1 暂停流程

1. SDK 调用 `POST /sandboxes/{sandboxID}/pause`。
2. Manager 按 namespace 查询并锁定沙箱状态，只接受 `running`。
3. Manager 生成 snapshot ID，保存恢复所需配置，但不保存明文 Host token。
4. Manager 调用原节点暂停接口，节点生成内存和文件系统快照并停止实例。
5. 节点确认成功后，Manager 将状态更新为 `paused`，将保留截止时间设置为当前时间加 24 小时。
6. Manager 释放该 namespace 的运行配额。
7. SDK 将本地状态更新为 paused，并关闭已有数据面连接。

重复暂停已经处于 paused 状态的沙箱返回成功，避免调用方重试产生第二份快照。

#### 3.2.2 恢复流程

1. SDK 调用 `resume()`，或调用 `connect()` 连接 paused 沙箱。
2. Manager 校验沙箱状态和暂停快照，读取原节点及恢复配置。
3. Manager 确认原节点可用并预留运行配额。
4. Manager 创建新的 Relay tunnel 和连接凭证。
5. Manager 通知原节点使用指定快照恢复同一 sandbox ID。
6. 恢复成功后更新 `running` 状态、开始时间、截止时间和连接信息，并删除已消费的暂停快照记录。
7. SDK 关闭旧数据面连接，替换新的 connect token 和访问地址。

恢复请求结果不明确时，Manager 不盲目重复创建。只有确认本次恢复实例已经清理，才允许再次恢复，避免出现同一 sandbox ID 对应多个运行实例。

#### 3.2.3 自动暂停流程

1. 到期任务发现 running 沙箱已到期且 `auto_pause=true`。
2. Manager 锁定数据库记录并重新确认状态、策略和截止时间，排除刚续期的旧扫描结果。
3. Manager 从 Redis 或 MySQL 读取完整恢复配置，调用节点生成快照并暂停。
4. Manager 将状态改为 paused，记录 24 小时保留截止时间并释放运行配额。
5. 暂停完成后 tunnel 仍作为 Gateway 唤醒与路由的稳定标识。

#### 3.2.4 Gateway 自动唤醒流程

1. Gateway 收到指向暂停 tunnel 的命令、文件、PTY 或代理请求。
2. Gateway 使用客户端证书调用 Manager 独立 mTLS 端口，并传入 tunnel ID。
3. Manager 查询全局 `t_sandbox`，只接受未过保留期且 `auto_resume=true` 的 paused 沙箱。
4. Manager 在行锁内恢复快照、运行配额和同一 tunnel；恢复完成返回 204。
5. Gateway 等待成功后重试原请求，客户端无需重新发起 connect。

#### 3.2.5 Timeout 与 Refresh 流程

1. Manager 校验沙箱属于调用 namespace、状态为 running、尚未到期。
2. 计算新的截止时间：timeout 直接覆盖，refresh 取原值与新值中的较大值。
3. 对正常生命周期同步更新节点停止时间、MySQL 和 Redis 到期索引。
4. 对 0 至 5 秒的短生命周期，不再向节点发送可能因网络耗时而失效的更新请求，由 Manager 到期任务完成回收。
5. 操作成功后按需异步延长 Relay tunnel，确保 tunnel 生命周期覆盖沙箱生命周期。

#### 3.2.6 到期流程

1. 后台任务从 Redis 和 MySQL 合并获取到期候选数据。
2. 再次读取并锁定数据库记录，防止刚完成续期或恢复的沙箱被误删。
3. `auto_pause=true` 的 running 沙箱执行暂停；其他到期沙箱清理节点实例和 Relay tunnel。
4. 更新数据库终态，清理 Redis 和暂停快照记录。
5. 节点清理失败时保留当前状态，下一轮继续重试，不提前声明回收成功。

### 3.3 关键业务算法

#### 截止时间计算

```text
set timeout: newEnd = now + timeout
refresh:     newEnd = max(oldEnd, now + duration)
connect:     running 时等同 refresh，paused 时按 timeout 恢复
```

这种区分让用户可以用 timeout 主动缩短成本窗口，同时保证 refresh 和 reconnect 不会意外缩短正在运行的沙箱。

#### 状态与并发协调

同一 sandbox ID 的 pause、resume、delete、timeout、refresh 和后台回收都以 MySQL 状态为最终依据。操作提交前重新确认状态和截止时间，避免以下竞争：

- timeout 刚延长，后台任务仍持有旧的到期候选；
- pause 与 delete 同时发生；
- 两个 Manager 实例同时恢复同一暂停沙箱；
- 节点恢复成功但调用响应超时，客户端立即重试。

#### 快照恢复一致性

暂停快照记录保存 sandbox ID、namespace、原节点、快照标识和恢复配置。恢复只消费与当前沙箱匹配的有效暂停快照，成功后删除该记录。快照与 namespace 不匹配、配置不完整或原节点不可用时，不创建替代沙箱。

#### tunnel 唤醒一致性

`sandbox_id` 继续使用 UUID，不因 Gateway 或 global 架构改变。Gateway 以当前请求已经携带的 `tunnel_id` 定位沙箱。恢复时 Relay upsert 必须返回相同 tunnel ID；如果发生变化，Manager 回滚本次恢复并返回失败，避免 Gateway 将原请求重试到错误实例。

### 3.4 关键代码

Manager 关键模块：

| 文件 | 作用 |
|---|---|
| `internal/handlers/sandbox_pause.go` | 暂停编排及快照记录 |
| `internal/handlers/sandbox_resume.go` | 快照恢复、配额和连接凭证更新 |
| `internal/handlers/sandbox_connect.go` | running 连接与 paused 自动恢复 |
| `internal/handlers/sandbox_auto_resume.go` | Gateway 按 tunnel ID 自动唤醒 |
| `internal/handlers/sandbox_deadline.go` | timeout、refresh、connect 共用截止时间逻辑 |
| `internal/handlers/sandbox_timeout.go` | 覆盖式生命周期设置 |
| `internal/handlers/sandbox_refresh.go` | 只延长生命周期 |
| `internal/orchestrator/orchestrator.go` | 节点暂停、恢复、截止时间同步和到期回收 |
| `cmd/internal_server.go` | 独立 mTLS 控制端口 |

SDK 关键模块：

| 文件 | 作用 |
|---|---|
| `python-sdk/src/devbox/sandbox.py` | Python 同步/异步生命周期接口 |
| `js-sdk/src/sandbox.ts` | JavaScript 生命周期接口 |
| `python-sdk/examples/validate_lifecycle.py` | Python 生命周期端到端验证入口 |
| `js-sdk/examples/validate-lifecycle.mjs` | JavaScript 生命周期端到端验证入口 |

### 3.5 接口定义

#### Manager HTTP API

| 方法 | 路径 | 请求 | 成功响应 | 说明 |
|---|---|---|---|---|
| POST | `/sandboxes/{sandboxID}/pause` | `{ "memory": true }`，Body 可省略 | 204 | 保存完整快照并暂停 |
| POST | `/sandboxes/{sandboxID}/resume` | `{ "timeout": 300 }`，Body 可省略 | 201 + Sandbox | 显式恢复并返回新连接信息 |
| POST | `/sandboxes/{sandboxID}/connect` | `{ "timeout": 300 }`，Body 可省略 | running 返回 200，恢复返回 201 | 连接或恢复沙箱 |
| POST | `/sandboxes/{sandboxID}/timeout` | `{ "timeout": 7200 }` | 204 | 覆盖剩余生命周期 |
| POST | `/sandboxes/{sandboxID}/refreshes` | `{ "duration": 7200 }` | 204 | 只延长剩余生命周期 |

#### Gateway 内部 API

该接口只监听 `INTERNAL_PORT`，强制校验 Gateway 客户端证书，不在公开 API 端口注册。

| 方法 | 路径 | 成功响应 | 说明 |
|---|---|---|---|
| POST | `/open-api-inner/v1/devbox-manager/tunnels/{tunnelId}/resume` | 204 | 已运行时幂等成功；暂停时按策略恢复 |

主要错误语义：

| HTTP 状态 | 场景 |
|---|---|
| 400 | 参数格式、timeout 范围或暂不支持的生命周期选项错误 |
| 404 | 沙箱不存在、已经到期或暂停快照不存在 |
| 409 | 状态不允许、配额不足或上次恢复结果尚待收敛 |
| 503 | 保存快照的原节点暂时不可用 |
| 500 | 快照、恢复或持久化过程发生内部错误 |

#### SDK API

Python：

```python
sandbox = Sandbox.create(
    lifecycle=SandboxLifecycle(on_timeout="pause", auto_resume=True)
)
sandbox.pause()
sandbox.resume(timeout=300)
Sandbox.connect(sandbox_id, timeout=300)
sandbox.set_timeout(7200)
sandbox.refresh(7200)
```

JavaScript：

```javascript
const sandbox = await Sandbox.create({
  lifecycle: { onTimeout: "pause", autoResume: true }
})
await sandbox.pause()
await sandbox.resume({ timeout: 300 })
await Sandbox.connect(sandboxId, { timeout: 300 })
await sandbox.setTimeout(7200)
await sandbox.refresh(7200)
```

`pause()` 会关闭当前 SDK 数据面连接。`resume()` 会更新当前 Sandbox 对象；`connect()` 会返回可用的 Sandbox 对象。SDK 的 `close()` 只关闭本地连接，`kill()` 才删除远端沙箱。

### 3.6 数据表设计

#### t_sandbox 生命周期字段

| 字段 | 说明 |
|---|---|
| `sandbox_id` | 沙箱唯一标识，暂停恢复期间保持不变 |
| `namespace` | 用户隔离范围 |
| `status` | `running`、`paused`、`killed` 等生命周期状态 |
| `node_id` | 沙箱及本地快照所在节点 |
| `start_time` | 本次运行开始时间，恢复后重新记录 |
| `end_time` | 当前生命周期截止时间 |
| `actual_end_time` | 实际终止时间 |
| `tunnel_id` | 当前运行实例对应的 Relay tunnel |
| `auto_pause` | 到期时暂停而不是销毁 |
| `auto_resume` | 是否允许 Gateway 流量唤醒 |
| `connect_token` | 加密保存的数据面连接凭证 |
| `token_expiration` | connect token 过期时间 |
| `tunnel_expiration` | tunnel 过期时间 |

#### t_snapshot

| 字段 | 说明 |
|---|---|
| `snapshot_id` | 单次暂停快照标识 |
| `sandbox_id` | 所属沙箱 |
| `namespace` | 所属隔离范围 |
| `template_id` | 沙箱原始模板标识 |
| `config` | 恢复所需沙箱配置，使用 `MEDIUMTEXT` |
| `is_paused` | 是否为暂停恢复快照 |
| `origin_node_id` | 保存快照的原节点 |
| `created_at` | 快照创建时间 |

暂停快照以 `(sandbox_id, namespace, is_paused)` 进行查询。恢复和删除按 snapshot ID 或 sandbox ID 清理记录，沙箱状态仍以 `t_sandbox` 为权威来源。`t_sandbox.tunnel_id` 建立查询索引，供全局 Manager 的 Gateway 唤醒入口快速定位沙箱。

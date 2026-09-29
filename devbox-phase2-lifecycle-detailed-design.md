# DevBox 沙箱生命周期增强详细设计

本文描述 DevBox Manager 与 Python SDK 的沙箱生命周期增强。Manager 是全局控制面，负责生命周期状态与资源编排；沙箱运行、快照和恢复由节点运行时完成。

## 1 价值描述

### 作为

作为通过 Python SDK 使用 DevBox 的开发者。

### 我要

我要暂停暂时不用的沙箱，在需要时恢复原有现场，并能够调整沙箱的剩余运行时间。

### 从而

从而保留文件、内存和进程状态，减少空闲资源占用，同时获得清晰、可控的沙箱生命周期。

### 现状

沙箱创建后持续运行到超时或主动删除。用户离开后不能保留现场，重新创建会丢失运行状态；生命周期调整和恢复能力也未形成完整闭环。

### 要求

- 支持手动暂停和恢复，恢复后继续使用同一 sandbox ID。
- 支持超时销毁或超时自动暂停，并可由访问流量自动唤醒。
- 主动恢复时重新取得数据面连接凭证，SDK 使用新凭证替换本地旧值。
- 支持覆盖式设置剩余时间，以及只延长不缩短的续期。
- 到期资源最终完成节点、Tunnel、缓存和状态清理。

## 2 功能描述

### 2.1 功能说明

#### 暂停与恢复

运行中的沙箱可以执行 `pause`。Manager 通知原节点保存内存与文件系统快照，成功后将沙箱置为 `paused` 并释放运行配额。

暂停沙箱可以通过 `resume` 显式恢复，也可以通过 Manager `connect` 获取连接凭证时恢复。恢复使用原节点快照，保持 sandbox ID 不变，并重新申请运行配额、恢复 Relay tunnel、签发新的 `connectToken`。SDK 使用响应中的新 Token 替换暂停前的 Token。

Manager `connect` 只负责确保沙箱可连接并返回凭证，不建立或保持数据面连接。实际连接由 SDK 使用 `connectToken` 访问 Gateway。

沙箱截止时间、Tunnel 租约和 Token 租约相互独立：沙箱截止时间决定运行或暂停，Tunnel 租约保证路由存在，`connectToken` 是固定 24 小时的访问凭证。SDK 在 Token 到期前通过 Manager `connect` 静默获取当前凭证；Manager 必要时向 Relay 续签。用户不直接管理 Token。

#### 生命周期策略

创建沙箱时可以选择：

- `onTimeout=kill`：到期后销毁沙箱，作为默认策略。
- `onTimeout=pause`：到期后生成完整快照并暂停。
- `autoResume=true`：允许 Gateway 在访问暂停沙箱时触发自动恢复。

`set_timeout` 将截止时间设置为当前时间加指定时长，可以缩短或延长；`refresh` 和运行态 `connect` 只延长现有生命周期。

#### Gateway 自动恢复

开启 auto resume 后，客户端仍按原地址访问 Gateway。Gateway 识别暂停 tunnel 后，由 `vsock_proxy` 挂起当前通道，并通过独立的 mTLS 接口按 tunnel ID 请求 Manager 恢复沙箱。Manager 恢复成功后，Gateway 向 `vsock_proxy` 下发恢复通道指令，继续处理原请求。

该流程不要求 SDK 再发起一次业务请求。Gateway 内部恢复接口只负责唤醒，不向 SDK 返回 Token；SDK 后续重新建立 Sandbox 句柄时，通过 Manager `connect` 获取当前连接凭证。

#### 到期处理

Manager 定期收敛到期状态。对于超时自动暂停的沙箱执行暂停，其余沙箱执行销毁；清理节点实例、Relay tunnel 和缓存后，将数据库状态更新为终态。暂停沙箱超过保留期后同样被清理。

### 2.2 约束与依赖

- 暂停和恢复依赖节点提供完整快照能力，当前快照只能在原节点恢复。
- 暂停沙箱保留 24 小时；原节点不可用时不能迁移到其他节点恢复。
- 自动恢复依赖 Gateway、`vsock_proxy`、Manager 内部 mTLS 接口和 Relay tunnel 协同。
- MySQL 保存权威生命周期状态，Redis 保存运行视图、到期索引和配额计数。
- 自动恢复必须保持 tunnel ID 不变，避免原请求被转发到错误实例。
- Relay 新签发 Token 不提前撤销尚未到期的旧 Token，保证唤醒中的请求可以完成。

## 3 实现设计

### 3.1 总体设计描述

| 组件 | 职责 |
|---|---|
| Python SDK | 提供生命周期接口，维护当前 Sandbox 状态和连接凭证 |
| Gateway / `vsock_proxy` | 识别暂停 tunnel、挂起请求、触发恢复并恢复数据通道 |
| Manager | 管理全局状态，编排快照、恢复、配额、Tunnel 和到期清理 |
| 节点运行时 | 生成快照、恢复实例并执行节点侧资源操作 |

核心状态流转：

```text
running -- pause / timeout policy --> paused
running -- timeout / delete -------> killed
paused  -- resume / connect -------> running
paused  -- retention expired ------> killed
```

### 3.2 业务流程

#### 暂停

1. SDK 请求暂停沙箱。
2. Manager 校验并锁定运行状态，记录快照标识与恢复配置。
3. 原节点保存内存和文件系统快照并停止实例。
4. Manager 将状态更新为 `paused`，设置暂停保留期并释放运行配额。
5. SDK 关闭已有数据面连接。

#### 主动恢复与 Connect

1. SDK 调用 `resume()`，或者对暂停沙箱调用 Manager `connect()`。
2. Manager 校验暂停状态、快照和原节点，预留运行配额。
3. Manager 恢复 Relay tunnel 并取得新的 `connectToken`。
4. 原节点从快照恢复同一沙箱。
5. Manager 更新运行状态、生命周期和连接信息，删除已消费的暂停快照记录。
6. SDK 使用响应中的新 Token 替换旧 Token，随后连接 Gateway。

#### Gateway 自动恢复

1. Gateway 收到暂停 tunnel 的数据面请求，`vsock_proxy` 挂起当前通道。
2. Gateway 使用客户端证书和 tunnel ID 调用 Manager 内部恢复接口。
3. Manager 定位沙箱并完成与主动恢复相同的资源编排。
4. Manager 返回成功后，Gateway 向 `vsock_proxy` 发送恢复通道指令。
5. `vsock_proxy` 恢复转发，原请求继续执行。

#### 生命周期调整与到期

1. `set_timeout` 覆盖截止时间；`refresh` 仅在新截止时间更晚时更新。
2. Manager 同步更新数据库、Redis 到期索引和节点截止时间，并确保 Tunnel 生命周期覆盖沙箱生命周期。
3. 到期任务重新确认沙箱状态和截止时间，避免续期与回收竞争。
4. 根据生命周期策略暂停或销毁沙箱，并完成关联资源清理。

### 3.3 关键业务算法

#### 截止时间

```text
set timeout: newEnd = now + timeout
refresh:     newEnd = max(oldEnd, now + duration)
connect:     running 时等同 refresh，paused 时执行恢复
```

#### 状态一致性

MySQL 是生命周期状态的最终依据。同一 sandbox ID 的暂停、恢复、删除、续期和后台回收在提交前重新确认状态，避免多个 Manager 实例重复恢复或使用过期扫描结果回收已续期沙箱。

#### 恢复一致性

恢复必须使用当前沙箱的有效暂停快照和原节点。Relay 恢复必须保持 tunnel ID 不变，并签发新的 `connectToken`。只有节点恢复和状态持久化均完成后，Manager 才返回成功。

### 3.4 关键代码

| 模块 | 作用 |
|---|---|
| `internal/handlers/sandbox_pause.go` | 暂停编排与快照登记 |
| `internal/handlers/sandbox_resume.go` | 主动恢复和 Gateway 自动恢复 |
| `internal/handlers/sandbox_connect.go` | 获取连接凭证，必要时恢复暂停沙箱 |
| `internal/handlers/sandbox_lifecycle.go` | 生命周期调整与 Tunnel 续期 |
| `internal/orchestrator/orchestrator.go` | 节点暂停、恢复和清理调用 |
| `python-sdk/src/devbox/sandbox.py` | Python 同步、异步生命周期接口 |

### 3.5 接口定义

#### Manager API

| 方法 | 路径 | 说明 |
|---|---|---|
| POST | `/sandboxes/{sandboxID}/pause` | 保存完整快照并暂停 |
| POST | `/sandboxes/{sandboxID}/resume` | 显式恢复并返回新连接凭证 |
| POST | `/sandboxes/{sandboxID}/connect` | 获取连接凭证；暂停时先恢复 |
| POST | `/sandboxes/{sandboxID}/timeout` | 覆盖剩余生命周期 |
| POST | `/sandboxes/{sandboxID}/refreshes` | 只延长剩余生命周期 |

Gateway 通过独立 mTLS 端口调用：

| 方法 | 路径 | 说明 |
|---|---|---|
| POST | `/open-api-inner/v1/devbox-manager/tunnels/{tunnelId}/resume` | 按 tunnel ID 幂等恢复允许自动唤醒的沙箱 |

#### Python SDK API

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

`pause()` 关闭当前 SDK 数据面连接；`resume()` 更新当前 Sandbox 对象及其连接凭证；`connect()` 返回一个可用于访问 Gateway 的 Sandbox 对象。`close()` 只关闭本地连接，`kill()` 才删除远端沙箱。

### 3.6 数据表设计

本期复用既有 `t_sandbox` 生命周期字段和 `t_snapshot` 快照表，不新增业务表。新增以下索引支持 Gateway 按 tunnel ID 唤醒：

| 表 | 变更 | 用途 |
|---|---|---|
| `t_sandbox` | `INDEX idx_sandbox_tunnel_id (tunnel_id)` | 根据 Gateway 提供的 tunnel ID 快速定位全局沙箱 |

# DevBridge Management Service 详细设计

本文描述 Management Service 的业务范围、业务流程及接口和数据契约，供 SE、测试及关联服务开发对齐。

## 1 价值描述

### 作为

作为已完成云账号登录的 DevBridge 用户。

### 我要

我要获得稳定的 Namespace 和安全的 API Key，并为 DevBridge、DevBox 等使用场景创建独立凭证。

### 从而

- 云账号身份能够稳定映射到 DevBridge 资源空间；
- 上层服务能够通过 API Key 识别用户及资源归属；
- 不同客户端和使用场景可以独立管理和撤销凭证；
- 同一云账号下的用户保持资源隔离，同时共享账户级额度。

### 现状

Relay Controller 已按照用户 Namespace 隔离 Tunnel，并按照账户 Namespace 管理共享额度。当前需要补齐云账号身份、Namespace 和 API Key 之间的统一映射，为上层服务提供稳定的用户身份入口。

### 要求

建立“云账号身份、Namespace、API Key”管理闭环，使用户登录后能够取得默认凭证，并持续管理不同场景的 API Key。

## 2 功能描述

### 2.1 功能说明

| 功能 | 说明 |
| --- | --- |
| 身份映射 | 一个云 Domain 对应一个账户 Namespace；一个用户对应一个独立用户 Namespace |
| 默认 API Key | 用户登录时按类型签发，同类型旧默认 Key 立即失效 |
| 类型 API Key | 用户可以为 DevBridge、DevBox 或不同设备创建独立 Key |
| Key 校验 | 校验 API Key，并返回用户身份、用户 Namespace 和账户 Namespace |
| Key 管理 | 查询 Key 元数据、创建附加 Key、删除附加 Key |
| 数据割接 | 已有 Namespace 映射可以预先导入，用户进入后继续沿用 |

API Key 业务规则：

| 项目 | 规则 |
| --- | --- |
| 默认 Key | `devbridge`、`devbox` 各 1 个；每次登录只轮换请求类型的默认 Key，不可删除 |
| 附加 Key | 每个类型最多 4 个，可独立删除，完整值只在创建时返回 |
| 类型 | `devbridge`、`devbox` |
| 格式 | `devbridge_<payload>`、`devbox_<payload>` |
| 名称 | 同一用户 Namespace 和类型内唯一，`default` 为系统保留名称 |
| 最近使用 | 成功校验 Key 后更新，列表通过 `lastUsedAt` 展示 |
| 权限 | 当前所有 Key 均代表同一用户 Namespace，类型用于区分用途 |

### 2.2 约束与依赖

#### 职责边界

| 组件 | 职责 |
| --- | --- |
| 上层身份服务 | 完成云账号登录，向 Management Service 传递可信的 Domain ID 和 User ID |
| Management Service | 管理身份映射、Namespace 和 API Key 生命周期 |
| Relay Service | 解析 API Key，并将用户 Namespace 和账户 Namespace 传递给 Relay Controller |
| Relay Controller | 根据两个 Namespace 完成资源隔离和账户额度归属 |
| 端侧 | 保存 API Key，并按客户端或使用场景选择对应 Key |

#### 业务约束

- Namespace 由云账号身份唯一确定，调用方只传递身份信息；
- 同一 Domain 下的用户共享账户 Namespace，各自拥有独立用户 Namespace；
- API Key 是用户凭证，持有者拥有对应用户 Namespace 的访问能力；
- 各类型默认 Key 由登录流程签发，附加 Key 用于长期使用或设备隔离；
- 附加 Key 原文丢失后，通过已有有效 Key 删除旧记录并重新创建；
- 已有用户割接时，身份映射在业务切流前完成导入。

#### 安全边界

- 服务间认证用于确认可信调用方；
- 默认 Key 接口同时校验上层身份服务凭证和用户身份信息；
- 其他接口根据 API Key 确定用户，不由请求参数选择 Namespace；
- 完整 API Key 只在必要的响应中返回，持久化数据只保留摘要和脱敏值；
- 密钥和服务凭证由部署密钥系统统一管理。

## 3 实现设计

### 3.1 总体设计描述

```text
用户登录
   |
   v
上层身份服务 -- Domain ID / User ID --> Management Service
                                             |
                            身份映射 + Namespace + API Key
                                             |
                                             v
                                      Management 数据

端侧 -- API Key --> Relay Service -- 校验及身份解析 --> Management Service
                         |
                         +-- 用户/账户 Namespace --> Relay Controller
```

Management Service 维护两级身份：

1. 账户身份对应账户 Namespace，用于共享套餐和额度；
2. 用户身份对应用户 Namespace，用于隔离 Tunnel 等用户资源。

API Key 对应一条用户凭证记录，再通过用户 Namespace 找到用户身份和账户身份。Key 内容本身不承载用户信息。

### 3.2 业务流程

| 流程 | 触发 | 核心处理 | 结果 |
| --- | --- | --- | --- |
| 签发默认 Key | 用户完成登录并选择类型 | 创建或读取身份和 Namespace，替换该类型默认 Key | 返回新 Key，同类型旧默认 Key 失效 |
| 校验 Key | 上层服务收到 API Key | 校验 Key，并找到用户及账户归属 | 返回两个 Namespace，或认证失败 |
| 查询 Key | 用户进入 Key 管理 | 查询当前用户的 Key 元数据 | 返回默认 Key 和附加 Key 列表 |
| 创建附加 Key | 用户选择名称和类型 | 校验名称、类型及该类型数量限制 | 返回一次完整 Key |
| 删除附加 Key | 用户选择已有 Key | 校验 Key 归属和类型 | 删除后立即失效 |
| 现有用户割接 | 业务切流前 | 导入身份和已有 Namespace 的对应关系 | 用户继续使用原资源隔离范围 |

推荐使用方式：

- DevBridge 和 DevBox 分别签发默认 Key，一个类型的登录不影响另一类型；
- 不同设备需要独立撤销能力时，分别创建附加 Key；
- 默认 Key 丢失后重新登录并轮换；
- 附加 Key 丢失后删除旧 Key 并重新创建。

### 3.3 关键业务规则

#### 身份稳定性

同一个 Domain ID 和 User ID 始终对应同一个用户 Namespace。同一 Domain 下新增用户时复用账户 Namespace，保证用户资源隔离与账户额度共享同时成立。

#### 默认 Key 轮换

每次登录随机生成新的默认 Key，只替换请求类型的默认 Key 记录。同一类型旧 Key 立即失效，另一类型默认 Key 和所有附加 Key 不受影响。轮换不增加 Key 数量，也不改变 Namespace。

#### 附加 Key 生命周期

附加 Key 随机生成并只返回一次完整值。列表只展示 ID、名称、类型、脱敏值和最近使用时间；删除后该 Key 立即失效。

#### Key 身份解析

服务根据 API Key 摘要找到凭证记录，再关联用户和账户。摘要用于快速、唯一地定位记录，不能还原完整 Key。成功校验同时更新最近使用时间；`POST /api-keys/check` 是唯一的 Key 校验和身份解析接口。

#### 一致性

- 身份、Namespace 和默认 Key 作为一个完整业务操作保存；
- 用户只能管理自己 Namespace 下的 Key；
- 每个类型的默认 Key 固定占用一个位置，附加 Key 数量最多为 4；
- 多实例并发创建时仍遵守名称唯一和数量上限。

### 3.4 关键模块

| 模块 | 职责 |
| --- | --- |
| 身份管理 | 建立和查询 Domain、User 与两个 Namespace 的映射 |
| 默认 Key 管理 | 按类型签发和轮换默认 Key |
| 类型 Key 管理 | 查询、创建和删除附加 Key |
| Key 校验 | 校验 API Key，并返回用户和账户归属 |
| 数据管理 | 保存身份、Key 元数据及业务约束 |

### 3.5 接口定义

接口前缀：

```text
/open-api-inner/v1/mgmt-service
```

| 方法与路径 | 身份信息 | 用途 |
| --- | --- | --- |
| `POST /api-keys/default` | 上层服务凭证、Domain ID、User ID、类型 | 签发或轮换该类型默认 Key |
| `POST /api-keys/check` | API Key | 校验 Key，解析当前用户及 Namespace |
| `GET /api-keys` | API Key | 查询当前用户的 Key 元数据 |
| `POST /api-keys` | API Key | 创建附加类型 Key |
| `DELETE /api-keys/{keyId}` | API Key | 删除当前用户的附加 Key |

`POST /api-keys/default` 使用以下请求头：

| Header | 含义 |
| --- | --- |
| `X-DevBridge-Proxy-Token` | 上层身份服务凭证 |
| `X-Domain-Id` | 已验证的云 Domain ID |
| `X-User-Id` | 已验证的云 User ID |

请求体指定默认 Key 类型：

```json
{
  "type": "devbridge"
}
```

成功响应返回：

| 字段 | 含义 |
| --- | --- |
| `domainId` / `userId` | 云账号身份 |
| `accountNamespace` | 账户级额度归属 |
| `namespace` | 用户资源隔离范围 |
| `type` | 默认 Key 类型 |
| `apiKey` | 对应类型的默认 API Key |

创建附加 Key 的请求体：

```json
{
  "name": "workstation",
  "type": "devbox"
}
```

创建成功时返回 Key 元数据和完整 `apiKey`。查询列表只返回元数据和脱敏值。

接口使用标准 HTTP 状态码：参数错误返回 `400`，认证失败返回 `401`，资源不存在返回 `404`，名称或数量冲突返回 `409`，内部错误返回 `500`。完整契约以 OpenAPI 为准。

### 3.6 数据表设计

| 表 | 用途 | 关键关系 |
| --- | --- | --- |
| `domain_account` | 云 Domain 与账户 Namespace 映射 | 一个 Domain 对应一个账户 Namespace |
| `user_identity` | 云用户与用户 Namespace 映射 | 一个账户包含多个用户，每个用户有独立 Namespace |
| `api_key` | API Key 元数据和摘要 | 每个用户在每种类型下包含一个默认 Key 和最多四个附加 Key |

`api_key` 记录包含 Key ID、所属 Namespace、名称、类型、脱敏值、摘要、创建时间和最近使用时间。默认 Key 与附加 Key 通过类型内的固定位置区分，用户身份停用后，其 Key 同步失去访问能力。

## 4 验证建议

| 业务范围 | 建议场景 | 预期结果 |
| --- | --- | --- |
| 身份映射 | 使用相同 Domain ID、User ID 和类型重复签发默认 Key | 两个 Namespace 保持不变，默认 Key 完成轮换 |
| 账户共享 | 同一 Domain 下使用两个不同 User ID | 用户 Namespace 不同，账户 Namespace 相同 |
| 账户隔离 | 使用两个不同 Domain ID | 账户 Namespace 和用户 Namespace 均不同 |
| 默认 Key | 分别签发两个类型的默认 Key | 两个 Key 值不同，且均可独立使用 |
| 默认 Key 轮换 | 对同一类型再次签发 | 返回新 Key；旧 Key 失效；另一类型默认 Key 仍有效 |
| 默认 Key 保护 | 尝试删除默认 Key | 返回业务冲突，默认 Key 继续有效 |
| 类型 Key | 分别创建 `devbridge` 和 `devbox` Key | Key 前缀、类型和所属用户正确 |
| Key 展示 | 创建后再次查询 Key 列表 | 列表只返回元数据和脱敏值，不返回完整 Key |
| 最近使用 | 使用一个 Key 调用 `/api-keys/check` 后查询列表 | 对应 Key 的 `lastUsedAt` 已记录 |
| Key 数量 | 每个类型分别连续创建 4 个附加 Key 后再次创建 | 两类互不占用配额，各自第 5 个附加 Key 返回数量冲突 |
| Key 名称 | 在同一类型使用重复名称，并在另一类型复用名称 | 同类型返回冲突，不同类型允许创建 |
| Key 删除 | 删除附加 Key 后再次使用该 Key | 删除成功，原 Key 认证失败，空闲位置可以重新使用 |
| 用户隔离 | 用户 A 尝试查询或删除用户 B 的 Key | 无法访问或修改用户 B 的数据 |
| 数据割接 | 预先导入身份和 Namespace 后获取默认 Key | 返回已导入的两个 Namespace，不生成新的映射 |
| 并发登录 | 同一用户、同一类型发生多个签发请求 | 只保留最后一次签发的默认 Key，不增加 Key 数量 |
| 并发创建 | 同一用户、同一类型并发创建多个附加 Key | 名称唯一且该类型附加 Key 不超过 4 个 |
| 服务身份 | 缺少可信服务认证或上层服务凭证 | 请求在进入身份开通前被拒绝 |
| 参数校验 | 缺少身份头、类型非法或 Key 名称非法 | 返回 `400` 及明确的错误目标 |
| 认证失败 | Proxy Token 或 API Key 无效 | 返回 `401`，不返回身份信息 |
| 接口前缀 | 使用统一前缀和旧路径分别调用 | 统一前缀正常处理，旧路径返回 `404` |

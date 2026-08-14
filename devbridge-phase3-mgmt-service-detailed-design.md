# DevBridge 三期 Management Service 详细设计

本文描述 DevBridge 三期 Management Service 的业务范围、实现方案及接口和数据契约，供 SE、测试及关联服务开发对齐。

## 1 价值描述

### 作为

作为已通过华为云账号登录的 DevBridge 用户。

### 我要

我要获得稳定的 Namespace 和 API Key，并为 DevBridge、DevBox 等使用场景创建可独立撤销的 API Key。

### 从而

- 用户无需自行创建或填写 Namespace；
- 上层服务可以通过 API Key 识别用户及资源隔离范围；
- 不同客户端和场景可以使用独立凭证，单个凭证泄露时能够单独撤销；
- 同一云账号下的主、子用户保持资源隔离，同时共享账户级额度。

### 现状

Relay Controller 已按 `X-Namespace` 隔离 Tunnel，并按 `X-Account-Namespace` 归属账户额度，但不负责云身份登录、Namespace 映射和用户 API Key 管理。上层服务缺少从华为云 `domainId/userId` 到 DevBridge 身份的统一映射。

### 要求

三期新增独立 Management Service，形成“可信云身份、Namespace、API Key”管理闭环。服务不接触 AK/SK，不实现华为云登录和浏览器跳转，也不允许调用方自行指定 Namespace。

## 2 功能描述

### 2.1 功能说明

| 功能 | 说明 |
| --- | --- |
| 身份映射 | 一个华为云 `domainId` 对应一个账户 Namespace；一个 `(domainId, userId)` 对应一个用户 Namespace |
| 默认 API Key | 用户首次登录后幂等创建；重复调用返回相同 Key；固定为 `devbridge` 场景且不可删除 |
| 场景 API Key | 每个用户最多创建 4 个附加 Key，场景为 `devbridge` 或 `devbox`，可以独立删除 |
| 身份解析 | 根据 API Key 返回 `domainId`、`userId`、账户 Namespace 和用户 Namespace |
| Key 管理 | 查询当前用户 Key 元数据、创建附加 Key、删除附加 Key |
| 数据割接 | 支持上线前导入现有 Namespace 映射，首次登录沿用已导入数据 |
| 自动建库 | 服务启动时按版本执行尚未运行的数据库迁移 |

API Key 规格：

| 项目 | 规格 |
| --- | --- |
| 默认 Key | 每个用户 1 个，`devbridge` 场景，不可删除，可通过可信登录流程重新获取 |
| 附加 Key | 每个用户最多 4 个，可删除，完整值只在创建响应中返回一次 |
| Key 格式 | `devbridge_<32位Base64URL>` 或 `devbox_<32位Base64URL>` |
| Key 强度 | 24 字节密钥材料，约 192 bit |
| Key 名称 | 用户 Namespace 内唯一；`default` 为系统保留名称 |
| 当前权限 | 默认 Key 和附加 Key 均代表同一用户 Namespace；场景用于端侧识别，不区分权限 |

### 2.2 约束与依赖

#### 职责边界

| 组件 | 职责 |
| --- | --- |
| 上层身份服务 | 完成华为云登录，取得可信 `domainId/userId`，调用默认 Key 接口并将结果交给端侧 |
| Management Service | 管理身份映射、Namespace、API Key 生命周期及 API Key 身份解析 |
| Relay Service | 使用解析后的用户 Namespace 和账户 Namespace 调用 Relay Controller |
| Relay Controller | 继续负责 Tunnel、Port、Token、计费和额度，不处理用户登录及 API Key 管理 |
| 端侧 | 保存 API Key；按 DevBridge、DevBox 或设备选择独立 Key |

#### 运行依赖

- Management Service 使用独立 MySQL/MariaDB 数据库，不依赖 Redis；
- 数据库账号需具备业务读写和迁移所需的建表权限；
- 所有实例必须配置相同的 `API_KEY_SECRET`；
- 上层身份服务与所有 Management Service 实例必须配置相同的 `IDENTITY_PROXY_TOKEN`；
- 现有用户割接时，需预先导入 `domainId`、`userId`、账户 Namespace 和用户 Namespace；
- 服务不提供 Namespace 的选择、枚举和删除接口；
- 迁移只向前执行，已执行版本记录在 `schema_migration`，SQL 内容由项目维护者管理。

#### 安全边界

- 所有接口启用 mTLS，TLS 1.2/1.3，调用方必须提供受信客户端证书；
- mTLS 认证调用服务，不代表终端用户身份；
- 默认 Key 接口额外校验 `X-DevBridge-Proxy-Token`，并只信任上层传入的 `X-Domain-Id/X-User-Id`；
- 其他管理接口使用 `X-API-Key` 识别用户，不接受 Namespace 请求参数；
- API Key 属于 Bearer Credential，持有者拥有对应 Namespace 的权限；
- 数据库只保存 Key 的 SHA-256 摘要和脱敏值，不保存完整 Key；
- `API_KEY_SECRET`、`IDENTITY_PROXY_TOKEN`、数据库密码、TLS 私钥和证书密码通过部署密钥机制提供，不进入代码仓库或日志。

## 3 实现设计

### 3.1 总体设计描述

```text
用户完成华为云登录
        |
        v
上层身份服务 -- domainId/userId + Proxy Token --> Management Service
                                                   |
                                +------------------+------------------+
                                |                                     |
                         身份与 Namespace                        API Key 管理
                                |                                     |
                                +------------------+------------------+
                                                   |
                                             mgmt_service DB

端侧 -- X-API-Key --> 上层服务 -- mTLS + X-API-Key --> Management Service
                           |                                |
                           |<----------- Identity ----------+
                           |
                           +-- Namespace Headers --> Relay Controller
```

Management Service 维护两级身份：

1. `domain_account` 表示华为云主账号，对应共享额度使用的 `accountNamespace`；
2. `user_identity` 表示主账号或子用户，对应隔离 Tunnel 资源的用户 `namespace`。

API Key 只负责找到一条 Key 记录。用户关系由该记录的 `namespace` 关联到 `user_identity` 和 `domain_account`，Key 内容本身不携带用户信息。

### 3.2 业务流程

| 流程 | 调用方 | 核心处理 | 结果 |
| --- | --- | --- | --- |
| 获取默认 Key | 上层身份服务 | 校验 mTLS、Proxy Token 和云身份；创建或读取账户、用户及默认 Key | 返回稳定的身份信息和默认 Key |
| 解析身份 | API Key 持有方的上层服务 | 对 Key 求摘要并查询有效账户和用户 | 返回用户及两个 Namespace，或返回未授权 |
| 查询 Key | 当前用户 | 通过 API Key 识别 Namespace，查询该 Namespace 下的 Key 元数据 | 返回默认 Key和附加 Key 的名称、场景、掩码及 ID |
| 创建附加 Key | 当前用户 | 校验名称和场景，在事务内分配空闲 Key 槽位 | 返回一次完整 Key；达到 4 个时返回冲突 |
| 删除附加 Key | 当前用户 | 按当前 Namespace 和 Key ID 删除 | Key 立即失效；默认 Key拒绝删除 |
| 现有用户割接 | 运维/部署流程 | 在业务切流前导入身份与 Namespace 映射 | 首次获取默认 Key时沿用原 Namespace |

推荐端侧使用方式：

- 默认 Key可直接用于 DevBridge，也是重新进入 Key 管理的稳定凭证；
- DevBox 创建独立 `devbox` Key；不同设备可继续创建独立场景 Key；
- 附加 Key完整值丢失后，通过默认 Key查询元数据、删除旧 Key并重新创建；
- 默认 Key丢失后，通过可信登录流程重新获取相同值。

### 3.3 关键业务算法

#### 默认 API Key

```text
material = HMAC-SHA256(
    API_KEY_SECRET,
    "devbridge-api-key\\0" + domainId + "\\0" + userId
)
payload  = Base64URL(material 的前 24 字节)
apiKey   = "devbridge_" + payload
```

相同密钥和云身份始终得到相同默认 Key，因此默认 Key接口天然幂等。更换 `API_KEY_SECRET` 后，用户下次调用默认 Key接口时完成默认 Key轮换，附加 Key不受影响。

#### 附加 API Key

```text
payload = Base64URL(CSPRNG 生成的 24 字节)
apiKey  = scenario + "_" + payload
```

附加 Key不可重建，数据库不保存原文，完整值只在创建成功时返回一次。

#### Key 身份解析

```text
keyHash = SHA-256(apiKey)
identity = api_key[keyHash]
             -> user_identity[namespace]
             -> domain_account[accountId]
```

`key_hash` 是唯一索引，用于快速定位记录。API Key具有足够随机强度，数据库泄露时不能从摘要实际还原原文。

#### 一致性与配额

- 账户、用户和默认 Key在同一事务中创建或读取；
- 数据库唯一约束保证一个云 Domain 只有一个账户映射、一个用户只有一个 Namespace；
- 默认 Key固定使用槽位 `0`，附加 Key使用槽位 `1` 至 `4`；
- 创建和删除附加 Key按用户串行修改，避免多副本并发突破 4 个附加 Key上限；
- Key名称和 Key摘要使用唯一索引保证最终一致性。

### 3.4 关键代码

本节仅列业务模块，具体实现以代码为准。

| Go 包 | 职责 |
| --- | --- |
| `cmd` | 启动迁移、数据库、mTLS HTTP Server及优雅停机 |
| `internal/httpapi` | 路由、mTLS 后的 Proxy Token/API Key认证、请求响应转换和 OpenAPI |
| `internal/service` | 身份开通、API Key生命周期和业务错误映射 |
| `internal/security` | 默认 Key派生、随机 Key与 ID生成、Key摘要和 PKCS12 mTLS |
| `internal/store` | 身份映射、Key查询、事务和数据库约束 |
| `migrations` | 执行未运行的前向 SQL并记录版本 |

### 3.5 接口定义

接口前缀：

```text
/v1
```

所有接口要求 mTLS。

| 方法与路径 | 额外认证 | 用途 |
| --- | --- | --- |
| `POST /v1/api-key` | Proxy Token、Domain ID、User ID | 幂等创建或获取默认 Key |
| `GET /v1/me` | API Key | 解析当前用户及 Namespace |
| `GET /v1/api-keys` | API Key | 查询当前用户的 Key元数据 |
| `POST /v1/api-keys` | API Key | 创建附加场景 Key |
| `DELETE /v1/api-keys/{keyId}` | API Key | 删除当前用户的附加 Key |

`POST /v1/api-key` 请求头：

| Header | 含义 |
| --- | --- |
| `X-DevBridge-Proxy-Token` | 上层身份服务与 Management Service 的共享凭证 |
| `X-Domain-Id` | 已验证的华为云 Domain ID |
| `X-User-Id` | 已验证的华为云 User ID |

成功响应：

| 字段 | 含义 |
| --- | --- |
| `domainId` / `userId` | 云身份 |
| `accountNamespace` | 账户级额度归属 |
| `namespace` | 用户资源隔离范围 |
| `apiKey` | 默认 DevBridge API Key |

`POST /v1/api-keys` 请求体：

```json
{
  "name": "workstation",
  "scenario": "devbox"
}
```

成功响应包含 `id`、`name`、`scenario`、`mask`、`isDefault`、`createdAt` 和只返回一次的 `apiKey`。

接口使用标准 HTTP 状态码：参数错误返回 `400`，认证失败返回 `401`，资源不存在返回 `404`，名称或配额冲突返回 `409`，内部错误返回 `500`。错误体统一为 `error.code/message/target/details` 结构。完整契约以 OpenAPI YAML 为准。

### 3.6 数据表设计

| 表 | 用途 | 关键约束 | 生命周期 |
| --- | --- | --- | --- |
| `domain_account` | 云 Domain 与账户 Namespace 映射 | `domain_id`、`account_namespace` 唯一 | 长期保留 |
| `user_identity` | 云用户与用户 Namespace 映射 | `(account_id, user_id)` 主键，`namespace` 唯一 | 长期保留 |
| `api_key` | API Key 元数据和摘要 | Namespace 内槽位、名称唯一，`key_hash` 全局唯一 | 随附加 Key删除；默认 Key长期保留 |
| `schema_migration` | 已执行迁移版本 | `version` 主键 | 长期保留 |

`api_key` 核心字段：

| 字段 | 含义 |
| --- | --- |
| `id` | Key管理 ID，不是 Key原文 |
| `namespace` | Key所属用户 Namespace |
| `slot` | `0` 为默认 Key，`1-4` 为附加 Key |
| `name` / `scenario` | Key名称和使用场景 |
| `key_mask` | 用于列表展示的脱敏值 |
| `key_hash` | 完整 API Key的 SHA-256 摘要及鉴权索引 |
| `created_at` | 创建时间 |

删除用户身份时级联删除其 API Key。账户和用户的 `status` 用于统一停用，停用后该身份下的所有 Key均不能通过认证。

# DevBridge Management Service 详细设计

本文描述 Management Service 的业务范围、流程和数据契约，供 SE、测试及关联服务开发对齐。

## 1 价值描述

### 作为

作为已完成云账号登录的 DevBridge 用户。

### 我要

我要获得稳定的 Namespace，并管理用于 DevBridge、DevBox 等场景的 API Key。

### 从而

- 上层服务能够识别用户及资源归属；
- 同一云账号下的用户相互隔离并共享账户额度；
- 不同客户端的凭证可以独立使用和撤销。

### 现状

Relay Controller 已按用户 Namespace 隔离 Tunnel，并按账户 Namespace 管理共享额度，需要补齐云账号身份、Namespace 和 API Key 的映射入口。

### 要求

用户首次接入时取得默认业务凭证，后续通过已确认的登录身份管理长期凭证。

## 2 功能描述

### 2.1 功能说明

| 功能 | 说明 |
| --- | --- |
| 身份映射 | 一个云 Domain 对应一个账户 Namespace；一个用户对应一个用户 Namespace |
| 默认 Key | 首次接入或 CLI 明确请求时按 Scope 签发，作为快速业务凭证 |
| 附加 Key | 按 Scope 创建具名长期凭证，可独立删除 |
| Key 校验 | 校验 API Key，返回用户及两个 Namespace |
| Key 管理 | 按已验证的 Domain ID 和 User ID 查询、创建和删除 Key |
| 数据割接 | 支持预先导入已有身份与 Namespace 映射 |

### 2.2 约束与依赖

| 组件 | 职责 |
| --- | --- |
| 上层身份服务 | 完成云账号登录并维护会话，传递可信的 Domain ID 和 User ID |
| Management Service | 管理身份映射、Namespace 和 API Key 生命周期 |
| Relay Service | 调用 Key 校验接口，并向 Relay Controller 传递两个 Namespace |
| Relay Controller | 完成用户资源隔离和账户额度归属 |

- 所有接口使用 mTLS，用户登录态由上层身份服务确认；
- Key 管理接口不接受 Namespace，也不使用 API Key 作为管理凭证；
- API Key 只代表对应用户 Namespace 的业务访问能力；
- 首次接入通过默认 Key 签发建立身份和 Namespace 映射；
- 完整 Key 只在签发时返回，持久化数据只保存摘要和脱敏值。

## 3 实现设计

### 3.1 总体设计描述

```text
用户登录
   |
   v
上层身份服务 -- 已验证的 Domain ID / User ID --> Management Service
                                             |
                                      身份、Namespace、Key

端侧 -- API Key --> Relay Service -- Key 校验 --> Management Service
                         |
                         +-- 用户/账户 Namespace --> Relay Controller
```

账户 Namespace 用于共享套餐和额度，用户 Namespace 用于隔离 Tunnel。API Key 关联用户 Namespace，并由此解析用户和账户归属。

### 3.2 业务流程

| 流程 | 触发 | 核心处理 | 结果 |
| --- | --- | --- | --- |
| 首次接入 | 上层确认用户身份并请求默认 Key | 建立身份映射和两个 Namespace，签发指定 Scope 默认 Key | 返回 Namespace 和完整 Key |
| 默认 Key 轮换 | 已认证 CLI 明确请求 | 替换指定 Scope 默认 Key | 新 Key 生效，同 Scope 旧 Key 失效 |
| Key 管理 | 上层传递 Domain ID 和 User ID | 解析用户 Namespace，查询、创建或删除 Key | 返回当前用户范围内的结果 |
| Key 校验 | 业务服务提交 API Key | 按摘要解析身份并记录最近使用时间 | 返回两个 Namespace，或认证失败 |
| 数据割接 | 业务切流前 | 导入云身份和已有 Namespace 的对应关系 | 用户继续使用原资源范围 |

### 3.3 关键业务算法

| 项目 | 设计 |
| --- | --- |
| 身份映射 | Domain ID 唯一映射账户 Namespace；同一 Domain 下的每个 User ID 映射独立用户 Namespace |
| 默认 Key | `devbridge`、`devbox` 各一个，不可删除；显式签发只轮换目标 Scope，不影响另一 Scope 和附加 Key |
| 附加 Key | 每个 Scope 最多四个；名称在用户 Namespace 和 Scope 内唯一；删除后立即失效 |
| Key 生成 | 24 字节安全随机值使用 Base64URL 编码，并添加 `devbridge_` 或 `devbox_` 前缀 |
| Key 存储 | 使用 SHA-256 摘要定位凭证，完整值不可从数据库恢复 |
| 最近使用 | `/api-keys/check` 成功后刷新 `lastUsedAt`，同一 Key 最多每分钟写入一次 |
| 并发一致性 | 身份和默认 Key 在同一事务保存；附加 Key 通过用户级串行化和数据库唯一约束保证数量与名称限制 |

### 3.4 关键代码

- HTTP 层只解析 mTLS 后的身份 Header、API Key 和请求体；
- Service 层区分身份管理和 Key 校验两条链路，完成参数与业务规则校验；
- Store 层负责身份映射、Key 摘要查询及事务一致性。

### 3.5 接口定义

接口前缀：`/open-api-inner/v1/mgmt-service`

| 方法与路径 | 身份信息 | 用途 |
| --- | --- | --- |
| `POST /api-keys/default` | Domain ID、User ID | 签发或轮换默认 Key |
| `POST /api-keys/check` | API Key | 校验 Key、刷新最近使用时间并解析身份 |
| `GET /api-keys` | Domain ID、User ID | 查询 Key 元数据 |
| `POST /api-keys` | Domain ID、User ID | 创建附加 Key |
| `DELETE /api-keys/{keyId}` | Domain ID、User ID | 删除附加 Key |

管理接口使用 `X-Domain-Id` 和 `X-User-Id`；校验接口使用 `X-API-Key`。

默认 Key 请求：

```json
{
  "scope": "devbridge"
}
```

附加 Key 请求：

```json
{
  "name": "workstation",
  "scope": "devbox"
}
```

默认 Key 响应包含云身份、两个 Namespace、Scope 和完整 Key；校验响应返回云身份及两个 Namespace；列表只返回元数据和脱敏值；附加 Key 的完整值只在创建响应中返回。完整接口契约以 OpenAPI 为准。

### 3.6 数据表设计

| 表 | 用途 | 关键关系 |
| --- | --- | --- |
| `domain_account` | 云 Domain 与账户 Namespace 映射 | 一个 Domain 对应一个账户 Namespace |
| `user_identity` | 云用户与用户 Namespace 映射 | 一个账户包含多个用户，每个用户拥有独立 Namespace |
| `api_key` | Key 元数据和摘要 | 每个用户在每个 Scope 下包含一个默认 Key 和最多四个附加 Key |

`api_key` 保存 Key ID、用户 Namespace、名称、Scope、脱敏值、摘要、创建时间和最近使用时间；用户身份停用后，其 Key 同步失效。

## 4 验证建议

| 业务范围 | 建议场景 | 预期结果 |
| --- | --- | --- |
| 身份与割接 | 同一 Domain 下使用多个用户，并导入一个已有用户的 Namespace | 用户 Namespace 相互隔离、账户 Namespace 共享，已有映射保持不变 |
| 默认 Key 轮换 | 并发轮换一个 Scope，同时使用另一 Scope 和附加 Key | 目标 Scope 只保留最后签发的默认 Key，其他 Key 不受影响 |
| 数量一致性 | 多实例并发创建同一 Scope 的附加 Key | 名称保持唯一，该 Scope 附加 Key 不超过四个 |
| 用户隔离 | 使用用户 A 的身份查询或删除用户 B 的 Key | 无法访问或修改用户 B 的数据 |
| 凭证安全 | 检查签发响应、列表和数据库记录 | 完整 Key 只在签发时返回，列表仅含脱敏值，数据库仅保存摘要 |
| 最近使用 | 调用 `/api-keys/check` 并跨一分钟观察 `lastUsedAt` | 校验成功后刷新，一分钟内不重复写入，超过一分钟后时间推进 |

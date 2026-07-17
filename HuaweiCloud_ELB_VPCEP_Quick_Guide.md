# container1 → container0：ELB + VPCEP 配置手册

用途：将 `container1` 账号中 `infraService` 工作负载的 `8443` 端口，通过华为云私网提供给 `container0` 账号中的 `containerService` 集群调用。

本方案不使用 ASM。

## 一、最终链路

```text
container0 / containerService Pod
  → container0 的 VPCEP 终端节点IP:8443
  → 跨账号 VPCEP 私网通道
  → container1 的 elb-relay-controller:8443
  → CCE LoadBalancer Service
  → infraService Pod:8443
```

## 二、推荐资源名称

| 资源 | 账号 | 推荐名称 |
|---|---|---|
| 私网 ELB | container1 | `elb-relay-controller` |
| CCE LoadBalancer Service | container1 | `svc-relay-controller` |
| VPCEP 终端节点服务 | container1 | `relay-controller` |
| VPCEP 终端节点 | container0 | `vpcep-relay-controller`（如果页面支持填写名称） |
| HTTPS 域名 | container0 调用 | 使用服务端证书允许的域名 |
| RDS 数据库 | container1 | `relay_controller` |
| RDS 数据库账号 | container1 | `relay_controller` |
| CCE 数据库凭据 Secret | container1 | `relay-controller-db-credentials` |

## 三、开始前准备

- `infraService` 与 `containerService` 所在区域必须相同。
- 确认 `infraService` 容器正在监听 `8443`。
- 获取 `container0` 的 IAM Domain ID（即账号 ID）。
- 确认 `infraService` 所属集群的 VPC 和默认节点子网。
- 确认 `containerService` 所属集群的 VPC 和默认节点子网。

## 四、container1 数据库准备

本节是在已有 RDS for MySQL 实例中创建业务数据库和业务账号，不是新购 RDS 实例。

### 步骤 1：创建数据库

在 `container1` 账号操作：

```text
华为云控制台 → 搜索 RDS → 实例管理
→ 进入 scheduleservice 所属 RDS 实例
→ 数据库与账号管理 → 数据库管理 → 创建数据库
```

填写：

| 配置项 | 值 |
|---|---|
| 数据库名称 | `relay_controller` |
| 字符集 | `utf8mb4` |
| 备注 | `relay-controller service database`（可选） |

单击“确定”完成创建。

### 步骤 2：创建数据库账号并授权

继续进入：

```text
数据库与账号管理 → 账号管理 → 创建账号
```

填写：

| 配置项 | 值 |
|---|---|
| 账号名称 | `relay_controller` |
| 访问主机 IP | `%` |
| 授权数据库 | 只选择 `relay_controller` |
| 数据库权限 | 按应用需要选择读写权限，不授权其他数据库 |
| 密码 | `<由密码管理系统生成的强密码>` |
| 确认密码 | 与上面一致 |

注意：RDS 创建账号页面需要填写数据库的实际密码。页面虽然以掩码显示，但不要把“应用加密后的密文”误当成数据库密码填写。实际密码应存入密码管理系统或 CCE Secret，不要写进操作手册、代码仓库或普通配置文件。

推荐在 `infraService` 中使用名为 `relay-controller-db-credentials` 的 CCE Secret 保存数据库账号和密码。

### 步骤 3：限制数据库网络访问

`访问主机 IP = %` 表示该数据库账号允许来自任意主机地址的登录请求，因此必须使用 RDS 安全组控制网络范围：

- RDS 不绑定公网 IP。
- RDS 安全组只放行 MySQL 实际端口，默认是 `3306`。
- 来源填写 `infraService` 集群实际使用的最小节点/容器子网 CIDR。
- 不要将数据库端口向 `0.0.0.0/0` 放开。

最后记录以下连接信息，但不要记录密码：

```text
DB_HOST=<RDS内网域名，优先于固定IP>
DB_PORT=3306
DB_NAME=relay_controller
DB_USERNAME=relay_controller
DB_PASSWORD=<从Secret读取>
```

## 五、ELB 与 VPCEP 配置步骤

### 步骤 1：container1 创建私网 ELB

在 `container1` 账号操作：

```text
华为云控制台 → 搜索 ELB → 弹性负载均衡 → 购买弹性负载均衡
```

填写：

| 配置项 | 值 |
|---|---|
| 名称 | `elb-relay-controller` |
| 企业项目 | `default` |
| 实例类型 | 独享型 |
| 规格类型 | 网络型 TCP/UDP |
| 网络类型 | IPv4 私网 |
| 弹性公网 IP | 不绑定 |
| 所属 VPC | `infraService` 所属集群的 VPC |
| 前端子网 | `infraService` 所属集群的默认节点子网 |
| 后端子网 | 如果页面要求填写，选择同 VPC 下可访问 CCE 的子网，优先使用默认节点子网 |

提交并等待 ELB 创建完成。

创建后记录：

- ELB 名称：`elb-relay-controller`
- ELB 的 IPv4 私有地址

此时不需要手工添加 Pod IP，也不需要手工创建监听器。下一步由 CCE Service 绑定 ELB，并创建监听器和后端。

### 步骤 2：container1 为 infraService 创建负载均衡 Service

进入：

```text
CCE → infraService 所属集群 → 工作负载
→ infraService → 访问方式 → 创建服务
```

填写：

| 配置项 | 值 |
|---|---|
| 服务名称 | `svc-relay-controller` |
| 类型/访问类型 | 负载均衡 |
| 负载均衡器 | 选择已有的 `elb-relay-controller` |
| 服务亲和 | 集群级别 |
| 协议 | TCP |
| 服务端口 | `8443` |
| 容器端口 | `8443` |
| 健康检查 | TCP，端口使用业务端口 |

创建完成后，CCE 会自动配置：

```text
ELB 监听器 8443
→ ELB 后端服务器组
→ CCE 节点或 infraService Pod
```

检查：

```text
ELB → elb-relay-controller → 监听器
```

必须看到：

- `8443` 监听器存在。
- 后端服务器组状态为“健康”。

如果 Pod 自己处理 HTTPS，监听器使用 `TCP:8443` 即可，TLS 会原样转发给 Pod。

### 步骤 3：container1 创建 VPCEP 终端节点服务

在 `container1` 账号操作：

```text
华为云控制台 → 搜索 VPCEP
→ VPC终端节点 → 终端节点服务 → 创建终端节点服务
```

填写：

| 配置项 | 值 |
|---|---|
| 名称 | `relay-controller` |
| 虚拟私有云 | `infraService` 所属集群的 VPC |
| 服务类型 | 接口 |
| 连接审批 | 关闭 |
| 后端资源类型 | 弹性负载均衡 |
| 负载均衡器 | `elb-relay-controller` |
| 协议 | TCP |
| 服务端口 | `8443` |
| 终端端口 | `8443` |

端口映射含义：

```text
container0 终端节点IP:8443
→ container1 ELB:8443
```

创建完成后：

```text
点击终端节点服务
→ 权限管理
→ 添加白名单记录
→ 输入 container0 的 IAM Domain ID
```

不要使用 `*`。

最后复制系统生成的“完整终端节点服务名称”，发送给 `container0`。对方创建终端节点时必须使用完整名称，而不只是 `relay-controller`。

如果 ELB 开启了访问控制，或者相关安全组有限制，需要放通：

```text
来源：198.19.128.0/17
协议：TCP
端口：8443
```

由于“连接审批”已关闭，`container0` 在白名单中时，创建终端节点后不需要 `container1` 再手工接受连接。

### 步骤 4：container0 购买 VPCEP 终端节点

在 `container0` 账号操作：

```text
华为云控制台 → 搜索 VPCEP
→ VPC终端节点 → 终端节点 → 购买终端节点
```

填写：

| 配置项 | 值 |
|---|---|
| 区域 | 与 container1 的终端节点服务相同 |
| 服务类别 | 按名称查找服务 |
| 服务名称 | 粘贴 container1 提供的完整终端节点服务名称，然后单击“验证” |
| 虚拟私有云 | `containerService` 所属集群的 VPC |
| 子网 | `containerService` 所属集群的默认节点子网 |
| IPv4 地址 | 自动分配 |
| 访问控制 | 首次联调可先关闭；后续如需开启，放行实际调用方网段 |

创建后等待状态变为“已接受”或“可用”，并记录终端节点的 IPv4 私有地址。

## 六、调用方式

### 1. 先检查端口

在 `container0` 的 Pod 中执行：

```bash
nc -vz <终端节点IP> 8443
```

### 2. 临时使用 IP 测试 HTTPS

```bash
curl -vk \
  https://<终端节点IP>:8443/open-api-inner/v1/relay-controller/tunnels
```

如果提示证书域名与 IP 不匹配，但已经完成 TLS 握手，说明 VPCEP 和 ELB 链路基本已经打通。

### 3. 正式使用证书域名

让 `container0` 在其 VPC 私网 DNS 中配置：

```text
<证书允许的域名> → <终端节点IP>
```

然后调用：

```text
https://<证书允许的域名>:8443/open-api-inner/v1/relay-controller/tunnels
```

不修改 DNS 的验证方式：

```bash
curl -v \
  --resolve <证书允许的域名>:8443:<终端节点IP> \
  https://<证书允许的域名>:8443/open-api-inner/v1/relay-controller/tunnels
```

如果使用私有 CA，`container0` 还需要信任对应根证书。如果服务启用了双向 TLS，还需要提供客户端证书和私钥。

## 七、验收清单

- [ ] RDS 数据库 `relay_controller` 已创建，字符集为 `utf8mb4`
- [ ] RDS 账号 `relay_controller` 仅获得目标数据库所需权限
- [ ] 数据库密码已存入 Secret，没有写入手册或代码
- [ ] RDS 安全组仅放行 `infraService` 所需网段和数据库端口
- [ ] `elb-relay-controller` 与 `infraService` 集群位于同一 VPC
- [ ] ELB 没有绑定公网 IP
- [ ] CCE Service 已选择 `elb-relay-controller`
- [ ] ELB 的 `8443` 监听器存在
- [ ] ELB 后端服务器组状态健康
- [ ] VPCEP 端口映射为 `8443 → 8443`
- [ ] `container0` IAM Domain ID 已加入白名单
- [ ] `container0` 终端节点状态已接受/可用
- [ ] `container0` Pod 可以连接终端节点 IP 的 `8443`
- [ ] 正式调用使用证书允许的域名

## 八、常见问题

| 现象 | 优先检查 |
|---|---|
| 找不到 ELB | 必须先创建 ELB，再创建 CCE LoadBalancer Service，并确保 ELB 与集群在同一 VPC |
| 找不到终端节点服务 | 区域是否一致、是否使用完整服务名称、container0 是否已加入白名单 |
| 连接超时 | 终端节点状态、端口映射、访问控制、安全组、ELB ACL |
| 502 Bad Gateway | ELB 后端健康状态、8443 的 HTTP/HTTPS 协议、应用内部上游 |
| 证书域名不匹配 | 使用证书域名，并解析到 container0 的终端节点 IP |
| tls alert bad certificate | 检查是否要求客户端证书（双向 TLS） |
| Access denied for user | 检查账号、实际密码、主机 IP 和数据库授权 |
| Communications link failure | 检查 RDS 内网地址、端口、VPC 和安全组规则 |

## 官方参考

- [CCE 创建负载均衡类型 Service](https://support.huaweicloud.com/usermanual-cce/cce_10_0681.html)
- [VPCEP 跨账号配置](https://support.huaweicloud.com/qs-vpcep/vpcep_02_0203.html)
- [创建 VPCEP 终端节点服务](https://support.huaweicloud.com/usermanual-vpcep/zh-cn_topic_0131645182.html)
- [RDS for MySQL 创建数据库](https://support.huaweicloud.com/usermanual-rds-mysql/rds_05_0019.html)
- [RDS for MySQL 修改账号主机 IP](https://support.huaweicloud.com/usermanual-rds-mysql/rds_05_0050.html)

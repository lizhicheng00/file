# 华为云 ELB + VPCEP 简明操作手册

适用场景：账号 A 的 CCE 服务，需要被账号 B 的另一个 CCE 集群通过私网调用。

示例端口统一使用 `8443`。

## 1. 最简架构

```text
账号 B 的 Pod
  → 账号 B 的 VPCEP 终端节点 IP:8443
  → 跨账号 VPCEP 私网通道
  → 账号 A 的私网 ELB:8443
  → CCE LoadBalancer Service
  → 业务 Pod:8443
```

单个服务、单个端口时不需要 ASM。只有需要域名/路径分流、灰度、限流、mTLS 等流量治理时，才考虑 ASM。

## 2. 开始前准备

- 两个账号的资源位于同一个华为云区域。
- 账号 A 的 Pod 已正常运行，并监听 `8443`。
- 账号 A 已获得账号 B 的“账号 ID”。
- 确认 Pod 的 `8443` 使用 HTTP 还是 HTTPS。

## 3. 账号 A：服务方配置

### 第一步：创建 CCE 负载均衡 Service

控制台路径：

```text
CCE → 集群 → 服务 → 创建服务
```

填写：

| 配置项 | 建议值 |
|---|---|
| 访问类型 | 负载均衡 |
| 命名空间 | 业务 Pod 所在命名空间 |
| 选择器 | 引用业务工作负载标签 |
| 负载均衡器 | 选择已有私网 ELB，或自动创建 |
| 服务亲和 | 集群级别 |
| 协议 | TCP |
| 服务端口 | 8443 |
| 容器端口 | 8443 |
| 健康检查 | 开启 |

CCE 会管理 ELB 监听器和后端，不要手工登记会变化的 Pod IP。

### 第二步：检查 ELB

控制台路径：

```text
ELB → 负载均衡器 → 选择实例
```

确认：

- ELB 有“IPv4 私有地址”。
- 存在 `8443` 监听器。
- 后端服务器组状态为“健康”。
- 如果 Pod 自己处理 HTTPS，最简单的监听器协议是 `TCP`，由 ELB 原样转发 TLS。

先从同 VPC 内测试 ELB：

```bash
curl -vk https://<ELB私网IP>:8443/health
```

如果 Pod 的 8443 实际是 HTTP，则改为：

```bash
curl -v http://<ELB私网IP>:8443/health
```

### 第三步：创建 VPCEP 终端节点服务

控制台路径：

```text
网络 → VPC终端节点 VPCEP → 终端节点服务 → 创建终端节点服务
```

填写：

| 配置项 | 建议值 |
|---|---|
| 区域 | 与 CCE、ELB 相同 |
| 服务类型 | 接口 |
| 连接审批 | 开启 |
| 后端资源类型 | 弹性负载均衡 |
| 负载均衡器 | 上一步使用的私网 ELB |
| 协议 | TCP |
| 服务端口 | 8443 |
| 终端端口 | 8443 |

端口含义：

```text
终端节点IP:8443 → ELB:8443
```

如果 ELB 开启了访问控制，或相关安全组有限制，按华为云 VPCEP 要求放通：

```text
来源：198.19.128.0/17
协议：TCP
端口：8443
```

### 第四步：添加账号 B 白名单

控制台路径：

```text
VPCEP → 终端节点服务 → 服务名称 → 权限管理 → 添加白名单记录
```

填写账号 B 的“账号 ID”。不要使用 `*`。

将以下信息发给账号 B：

- 区域
- 终端节点服务完整名称
- 协议：TCP
- 终端端口：8443
- HTTPS 证书对应的服务域名（如果有）

## 4. 账号 B：调用方配置

账号 B 操作：

```text
VPCEP → 终端节点 → 购买终端节点
```

填写：

- 区域与服务方相同。
- 服务类别选择“按名称查找服务”。
- 输入账号 A 提供的终端节点服务完整名称并验证。
- VPC 选择调用方 CCE 所在 VPC。
- 选择调用方 CCE 可以访问的子网。
- 创建完成后记录终端节点私网 IP。

如果账号 A 开启了连接审批，账号 A 还需要执行：

```text
终端节点服务 → 连接管理 → 接受
```

## 5. 调用方式

### HTTP 或普通 TCP

可以直接访问调用方账号中的终端节点 IP：

```text
http://<终端节点IP>:8443/接口路径
```

### HTTPS

不要长期使用 IP 访问证书域名。让账号 B 在其 VPC 私网 DNS 中配置：

```text
证书域名 → 终端节点私网IP
```

然后调用：

```text
https://<证书域名>:8443/接口路径
```

无需先改 DNS 的临时测试命令：

```bash
curl -v \
  --resolve <证书域名>:8443:<终端节点IP> \
  https://<证书域名>:8443/open-api-inner/v1/relay-controller/tunnels
```

## 6. 快速排障

| 现象 | 优先检查 |
|---|---|
| 连接超时 | 区域、白名单、连接审批、端口映射、终端节点访问控制、安全组/ELB ACL |
| Connection refused | ELB 监听器、终端端口、服务端口 |
| 502 Bad Gateway | ELB 后端是否健康、HTTP/HTTPS 协议是否一致、应用内部上游是否可用 |
| 404 | URL 路径或 Host 不匹配 |
| 证书域名不匹配 | 使用证书域名访问，并将该域名解析到终端节点 IP |
| unable to get local issuer certificate | 调用方需要信任服务端证书的 CA |
| tls alert bad certificate | 可能启用了双向 TLS，需要正确的客户端证书 |

排查顺序：

```text
Pod 本机:8443
→ ELB私网IP:8443
→ VPCEP终端节点IP/域名:8443
```

## 7. 最终检查清单

- [ ] Pod 的 8443 在集群内可访问
- [ ] ELB 监听器 8443 存在
- [ ] ELB 后端状态健康
- [ ] VPCEP 端口映射为 `8443 → 8443`
- [ ] 账号 B 已加入白名单
- [ ] VPCEP 连接状态已接受/可用
- [ ] 调用方使用终端节点 IP，或使用解析到该 IP 的证书域名

## 官方参考

- [CCE 创建负载均衡类型 Service](https://support.huaweicloud.com/usermanual-cce/cce_10_0681.html)
- [VPCEP 跨账号配置](https://support.huaweicloud.com/qs-vpcep/vpcep_02_0203.html)
- [创建 VPCEP 终端节点服务](https://support.huaweicloud.com/usermanual-vpcep/zh-cn_topic_0131645182.html)

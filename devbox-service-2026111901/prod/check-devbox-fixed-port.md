# 用固定端口验收 DevBox

只对新建的临时验收沙箱操作。需要能访问 Bridge Service 的 REST 地址，以及与该隧道同一 namespace 的 API Key。Bridge API 地址用实际环境的配置，SDK 返回的隧道域名用于最后的 DevBox 数据面测试。

1. 用 SDK 创建临时沙箱，读取其 connect 返回的域名及 tunnel ID。
2. 用 Bridge Service 的 `POST /v1/tunnels/{tunnelId}/ports` 增加一条端口绑定。请求带 `X-API-Key` 和 `Content-Type: application/json`，请求体如下。

   ```json
   {"port":49983,"protocol":"auto","allowAnonymous":false}
   ```

3. 用 `GET /v1/tunnels/{tunnelId}/ports/49983` 确认该绑定。若增加绑定返回 409，先读现有绑定并核对协议和匿名访问配置。
4. 让临时沙箱的 Relay host 连接重新注册到同一 tunnel ID。Gateway 在 host 注册时读取端口列表，已有会话可能仍持有旧配置。
5. 用原 SDK 连接参数、认证和 TLS，重试在沙箱里执行 `echo devbox-ok`。命令输出 `devbox-ok` 才算固定端口链路通过。若环境仍需临时映射域名到 ELB，保留域名作为 TLS SNI。
6. 用 SDK 删除临时沙箱。

这次验收覆盖 envd 和 SDK 命令执行。动态端口仍需单独验证。

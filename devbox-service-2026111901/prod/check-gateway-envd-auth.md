# Gateway 到 envd 的鉴权核对

Relay 端口列修改后，临时沙箱的 envd /health 返回 204，命令执行返回 401 invalid connect token。create 和 connect 返回的访客 token 一致。验收沙箱已删除。

在 CCE 打开实际接收 DevBox 公网流量的 Gateway 工作负载，只核对两项。

1. 记录运行中的 Gateway 容器完整镜像 tag 或 digest。代码提交 00aa2e9 引入 49983 端口的凭据注入，fc9edee 恢复启动时的 DevBox 开关初始化。用镜像构建记录确认包含这两项。
2. 查运行中 Gateway 容器的环境配置，确认 devbox.grpc.target 有非空值。若工作负载通过 envFrom 载入配置，核对它引用的配置对象里该键是否存在。只需回传是否有值，无需回传证书、私钥或任何 token。

当前源码对 49983 请求使用 Gateway 派生的 X-Devbox-Connect-Token。envd 的 /health 跳过这一步，命令接口会校验该凭据，因此 health 204 与命令 401 可以同时出现。镜像和开关都确认后，再查 Gateway 与 Manager 初始化 envd 使用的凭据是否一致。

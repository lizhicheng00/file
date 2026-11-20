# 生产 Gateway 自动唤醒核对

同一个生产验收沙箱中，访客访问返回 503 sandbox wakeup failed，沙箱仍为 paused。直接调用生产 Manager /resume 后恢复成功，原文件保留。另一轮通过到期自动暂停也复现了访客 503。两个验收沙箱均已删除。

1. 在 CCE 查看实际接收生产 DevBox 流量的 Gateway 容器配置，确认 devbox.grpc.target 最终指向生产 Manager 的 gateway-grpc Service。
2. 如果两个工作负载在同一个集群，并且 Service 名为 devbox-service、命名空间为 devbox-infra、Service 端口为 8445，可以使用 devbox-service.devbox-infra.svc:8445。跨集群时改用 Gateway 所在网络可达的生产 Manager 私网 gRPC 地址和真实端口。核对 devbox.grpc.server.name 与目标证书 SAN，以及 Gateway 客户端证书和 CA。
3. 若 target 已指向生产，查看 Gateway 容器日志中的 resumed visitor: wakeup failed。本轮对照隧道 ID 为 grnvincu，另一次到期测试 ID 为 xoqh4xum。记录 gRPC 状态和错误原因即可。
4. 配置生效后，用一个新沙箱开启 autoResume。等待沙箱处于 paused，再用原访客连接直接发起命令。确认命令成功、沙箱回到 running、暂停前文件仍在，然后删除验收沙箱。

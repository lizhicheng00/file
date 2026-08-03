# Pixel + Clash Meta：减少 ChatGPT App 的 TLS 报错

## 先说结论

节点本身“没开 TLS”，不等于 ChatGPT 的 HTTPS 没有 TLS。ChatGPT App 到服务器仍然会校验证书。

偶发 `TLS verification failed` 更常见的原因是：

- ChatGPT 的不同域名走了不同线路，部分直连、部分代理；
- DNS 被污染，或 Android 私人 DNS 绕过了 Clash；
- 节点丢包、切换 IP，登录请求中途断开；
- AdGuard、抓包软件或其他应用安装证书并拦截 HTTPS；
- 手机时间不准。

## 最快的稳定设置

### 1. 手机系统

1. Pixel 设置 → **系统 → 日期和时间**。
2. 打开“自动设置时间”和“自动设置时区”。
3. 设置 → **网络和互联网 → 私人 DNS**，先改为“自动”或“关闭”。
4. 暂停 AdGuard、HTTP Canary、抓包工具、杀毒软件的 HTTPS 扫描。
5. 不要给 Clash 安装任何用于“解密 HTTPS”的 CA 证书；正常代理不需要它。

### 2. Clash Meta

1. 更新 Clash Meta/Mihomo 内核。
2. 模式选择 **规则**；排错时可以暂时切到 **全局**。
3. 开启 **TUN 模式**。
4. TUN Stack 优先选 **Mixed**；不稳定再试 **System**。
5. 开启：
   - Auto Route
   - Auto Detect Interface
   - DNS Hijack
   - Strict Route（如果应用提供）
6. 关闭 IPv6 测试一次。如果错误消失，就保持 Clash DNS 和 TUN 中的 IPv6 关闭。
7. Android 设置中允许 Clash：
   - 后台运行；
   - 电池“不受限制”；
   - 始终开启 VPN；
   - “无 VPN 时阻止连接”（确认其他应用都能正常联网后再开）。

## 推荐 DNS 覆写

如果客户端支持“覆写 / Mixin / 扩展配置”，可加入：

```yaml
dns:
  enable: true
  ipv6: false
  enhanced-mode: fake-ip
  default-nameserver:
    - 223.5.5.5
    - 119.29.29.29
  nameserver:
    - https://dns.alidns.com/dns-query
    - https://doh.pub/dns-query
  fallback:
    - https://1.1.1.1/dns-query
    - https://dns.google/dns-query
  fallback-filter:
    geoip: true
    geoip-code: CN

tun:
  enable: true
  stack: mixed
  auto-route: true
  auto-detect-interface: true
  strict-route: true
  dns-hijack:
    - any:53
```

如果订阅配置已经包含 `dns` 或 `tun`，不要重复写两份；在客户端的覆写功能中修改对应字段。

## 让 ChatGPT 相关域名固定走同一组节点

把下面规则放在 `GEOIP`、`GEOSITE`、`MATCH` 等通用规则之前。将 `ChatGPT` 改成你配置中的代理组名称：

```yaml
rules:
  - DOMAIN-SUFFIX,chatgpt.com,ChatGPT
  - DOMAIN-SUFFIX,openai.com,ChatGPT
  - DOMAIN-SUFFIX,oaistatic.com,ChatGPT
  - DOMAIN-SUFFIX,oaiusercontent.com,ChatGPT
  - DOMAIN-SUFFIX,auth0.com,ChatGPT
  - DOMAIN-SUFFIX,arkoselabs.com,ChatGPT
  - DOMAIN-SUFFIX,statsig.com,ChatGPT
  - DOMAIN-SUFFIX,statsigapi.net,ChatGPT
```

`ChatGPT` 组先固定选择一个稳定节点，不要使用每几分钟自动切换的负载均衡。优先尝试支持 TLS/REALITY 的 VLESS、Trojan、Hysteria2 或 TUIC 节点。节点外层 TLS 主要改善抗干扰和稳定性，但不能代替上面的 DNS、路由检查。

## 修改后这样重连

1. 保存配置并重载订阅。
2. 断开 Clash，再重新连接。
3. 强制停止 ChatGPT App。
4. 清除 ChatGPT **缓存**，先不要清除数据。
5. 重新打开 ChatGPT 并登录。

## 仍然报错时，按顺序判断

1. Clash 切到**全局模式**并固定一个节点。
   - 全局正常：规则漏域名或分流不一致。
   - 全局仍失败：继续下一步。
2. 换一个稳定节点，避免频繁自动切换。
   - 换节点恢复：原节点丢包、出口受限或线路被干扰。
3. 浏览器打开 `https://chatgpt.com`。
   - 浏览器和 App 都失败：优先检查节点、DNS、系统时间。
   - 浏览器正常但 App 失败：优先检查 HTTPS 拦截证书、私人 DNS和 App 缓存。
4. 查看 Clash 日志，搜索 `openai`、`chatgpt`、`oai`、`auth0`。
   - 出现 `DIRECT`：补齐规则。
   - 出现 DNS/timeout：检查 TUN、DNS Hijack 和节点。
   - 出现 certificate/unknown CA：关闭 HTTPS 解密软件并移除其用户 CA。

## 建议最终组合

- 规则模式；
- TUN + Mixed；
- DNS Hijack；
- IPv6 暂时关闭；
- Android 私人 DNS 设为自动或关闭；
- ChatGPT 全部域名固定到同一个稳定节点；
- 不安装 HTTPS 解密证书；
- 节点不要高频自动切换。


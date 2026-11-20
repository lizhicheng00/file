-- 在生产 Relay / DevBridge 的 MySQL 中执行。
-- 将空字符串改成仍在运行的新验收沙箱的 tunnel ID。空字符串不返回结果。
-- SET 只设置当前连接的变量，SELECT 只读。
SET @devbox_tunnel_id = '';

SELECT t.tunnel_id,
       t.cluster_id,
       t.type,
       t.deleted,
       p.port,
       p.protocol,
       p.allow_anonymous
FROM t_tunnel AS t
LEFT JOIN t_tunnel_port AS p ON p.tunnel_code = t.tunnel_code
WHERE @devbox_tunnel_id <> ''
  AND t.tunnel_id = @devbox_tunnel_id
ORDER BY p.port;

-- 先运行 check-relay-port-schema.sql，确认 Bridge 业务库中的列为
-- BIGINT UNSIGNED NOT NULL、无默认值或额外属性，且 ports_outside_signed_bigint 为 0。
-- 列类型变更可能重建表并阻塞写入，请在变更窗口执行。
ALTER TABLE t_tunnel_port
    CHANGE COLUMN port port BIGINT NOT NULL
    COMMENT 'port, business range 1-65535, -1 full access for devbox';

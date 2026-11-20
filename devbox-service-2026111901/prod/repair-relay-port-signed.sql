-- 在已确认的生产 Bridge Service 业务库和变更窗口执行。
-- 先运行 check-relay-port-schema.sql，确认当前列为 BIGINT UNSIGNED NOT NULL、
-- 无默认值或额外属性，且 ports_outside_signed_int 为 0。
-- 类型变更可能重建表并阻塞写入。lock_wait_timeout 仅限制获取元数据锁的等待。
-- 变更后新建验收沙箱，用 check-relay-tunnel-ports.sql 检查新记录是否为 -1。
-- 本脚本不改写历史 port=0 的记录。

SET @relay_old_lock_wait_timeout = @@SESSION.lock_wait_timeout;
SET @relay_old_sql_mode = @@SESSION.sql_mode;
SET SESSION lock_wait_timeout = 5;
SET SESSION sql_mode = IF(
    FIND_IN_SET('STRICT_ALL_TABLES', @relay_old_sql_mode) > 0,
    @relay_old_sql_mode,
    CONCAT_WS(',', NULLIF(@relay_old_sql_mode, ''), 'STRICT_ALL_TABLES')
);

ALTER TABLE t_tunnel_port
    MODIFY COLUMN port INT NOT NULL
    COMMENT 'port, business range 1-65535, -1 full access for devbox';

SET SESSION sql_mode = @relay_old_sql_mode;
SET SESSION lock_wait_timeout = @relay_old_lock_wait_timeout;

SHOW COLUMNS FROM t_tunnel_port LIKE 'port';

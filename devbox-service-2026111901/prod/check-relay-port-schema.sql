-- 在生产 Relay / DevBridge 的 MySQL 查询窗口选中业务库后执行。
-- 仅查询当前库的列定义和 SQL 模式。新版本代码使用 t_tunnel_port。
SELECT DATABASE() AS selected_schema,
       @@GLOBAL.sql_mode AS global_sql_mode,
       @@SESSION.sql_mode AS query_session_sql_mode;

SELECT TABLE_NAME,
       COLUMN_TYPE,
       IS_NULLABLE,
       COLUMN_DEFAULT,
       COLUMN_COMMENT
FROM information_schema.COLUMNS
WHERE TABLE_SCHEMA = DATABASE()
  AND TABLE_NAME IN ('tunnel_port', 't_tunnel_port')
  AND COLUMN_NAME = 'port'
ORDER BY TABLE_NAME;

-- 确认选中生产 Bridge Service 的业务库，且当前版本使用 t_tunnel_port。
-- 修复前预期 port 为 BIGINT UNSIGNED NOT NULL、无默认值或额外属性。
SHOW CREATE TABLE t_tunnel_port;

-- 必须为 0 才能缩到有符号 INT。0 是历史异常值，修复 SQL 会原样保留。
SELECT COUNT(*) AS ports_outside_signed_int
FROM t_tunnel_port
WHERE port > 2147483647;

-- 新版 Bridge Service 的迁移版本。若该表不存在，核对生产镜像及旧迁移记录。
SELECT version_id, is_applied, tstamp
FROM goose_db_version
ORDER BY id;

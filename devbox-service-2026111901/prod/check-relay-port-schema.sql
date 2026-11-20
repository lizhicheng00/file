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

-- Replace with an active Tunnel ID.
SET @tunnel_id = 'replace_me';
SET @session_id = CONCAT('metering-verify-', REPLACE(UUID(), '-', ''));
SET @base_time = UNIX_TIMESTAMP() - 360;

-- Default: 1 MiB * 12 = 12 MiB.
SET @usage_bytes = 1048576;
-- Quota test: 512 MiB * 12 = 6 GiB.
-- SET @usage_bytes = 536870912;

INSERT INTO tunnel_metering (
    account_id,
    cluster_id,
    tunnel_id,
    session_id,
    usage_bytes,
    reported_at,
    created_at,
    settled
)
SELECT
    t.account_id,
    t.cluster_id,
    t.tunnel_id,
    @session_id,
    @usage_bytes,
    @base_time + sample.offset_seconds,
    UNIX_TIMESTAMP(),
    0
FROM tunnel t
CROSS JOIN (
    SELECT 0 AS offset_seconds
    UNION ALL SELECT 30
    UNION ALL SELECT 60
    UNION ALL SELECT 90
    UNION ALL SELECT 120
    UNION ALL SELECT 150
    UNION ALL SELECT 180
    UNION ALL SELECT 210
    UNION ALL SELECT 240
    UNION ALL SELECT 270
    UNION ALL SELECT 300
    UNION ALL SELECT 330
) sample
WHERE t.tunnel_id = @tunnel_id
  AND t.deleted = 0
  AND t.expiration > UNIX_TIMESTAMP();

SELECT
    @session_id AS session_id,
    COUNT(*) AS inserted_records,
    SUM(usage_bytes) AS inserted_bytes
FROM tunnel_metering
WHERE session_id = @session_id;

-- Account-level quota state maintained by Relay Controller.
ALTER TABLE billing_account
    ADD COLUMN quota_blocked_until BIGINT UNSIGNED NOT NULL DEFAULT 0
        COMMENT 'traffic blocked before this unix second';

-- Run after billing_period.billed_bytes is updated in the same settlement transaction.
UPDATE billing_account a
JOIN billing_period bp
  ON bp.account_id = a._id
 AND bp.period_start = #{periodStart}
SET a.quota_blocked_until = CASE
    WHEN bp.billed_bytes >= bp.quota_bytes THEN bp.period_end
    ELSE 0
END
WHERE a._id = #{accountId};

-- Gateway connection check.
-- Inputs: tunnelId, clusterId and now (Unix seconds).
-- Returns 1 when the tunnel may accept traffic, otherwise 0.
SELECT EXISTS (
    SELECT 1
    FROM tunnel t
    JOIN billing_account a ON a._id = t.account_id
    WHERE t.tunnel_id = #{tunnelId}
      AND t.cluster_id = #{clusterId}
      AND t.deleted = 0
      AND t.expiration > #{now}
      AND a.status = 'active'
      AND a.quota_blocked_until <= #{now}
) AS allowed;

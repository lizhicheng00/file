-- Account-level quota state maintained by Relay Controller.
ALTER TABLE billing_account
    ADD COLUMN quota_blocked_until BIGINT UNSIGNED NOT NULL DEFAULT 0
        COMMENT 'traffic blocked before this unix second';

-- Preserve already exhausted accounts when upgrading.
UPDATE billing_account a
JOIN (
    SELECT account_id, MAX(period_end) AS blocked_until
    FROM billing_period
    WHERE billed_bytes >= quota_bytes
    GROUP BY account_id
) exhausted ON exhausted.account_id = a._id
SET a.quota_blocked_until = exhausted.blocked_until;

-- Run after billing_period.billed_bytes is updated in the same settlement transaction.
UPDATE billing_account a
JOIN billing_period bp
  ON bp.account_id = a._id
 AND bp.period_start = #{periodStart}
SET a.quota_blocked_until = GREATEST(a.quota_blocked_until, bp.period_end)
WHERE a._id = #{accountId}
  AND bp.billed_bytes >= bp.quota_bytes
  AND a.quota_blocked_until < bp.period_end;

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

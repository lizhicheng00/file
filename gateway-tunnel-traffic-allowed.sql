-- Inputs: tunnelId, clusterId, periodStart (UTC month start), now (Unix seconds).
-- Returns 1 when the tunnel may accept traffic, otherwise 0.
SELECT EXISTS (
    SELECT 1
    FROM tunnel t
    JOIN billing_account a ON a._id = t.account_id
    JOIN billing_plan p ON p.plan_code = a.plan_code
    LEFT JOIN billing_period bp
      ON bp.account_id = t.account_id
     AND bp.period_start = #{periodStart}
    WHERE t.tunnel_id = #{tunnelId}
      AND t.cluster_id = #{clusterId}
      AND t.deleted = 0
      AND t.expiration > #{now}
      AND a.status = 'active'
      AND COALESCE(bp.billed_bytes, 0)
          < COALESCE(bp.quota_bytes, p.monthly_quota_bytes)
) AS allowed;

-- Aggregate the many-side before joining: each policy's exposure appears once.
CREATE VIEW policy_fact AS
WITH claim_totals AS (
    SELECT policy_id, COUNT(*) AS claim_count,
           SUM(paid_amount_usd) AS total_paid_usd
    FROM claims GROUP BY policy_id
)
SELECT p.*, COALESCE(c.claim_count, 0) AS claim_count,
       COALESCE(c.total_paid_usd, 0.0) AS total_paid_usd
FROM policies p
LEFT JOIN claim_totals c ON p.policy_id = c.policy_id;


-- Full-book descriptive results. Test rows remain excluded from model training.
-- Ratio of totals gives exposure-weighted frequency and claim-weighted severity.
WITH groups AS (
    SELECT 'overall' AS dimension, 'All policies' AS group_name, * FROM policy_fact
    UNION ALL
    SELECT 'driver_age', driver_age_group, * FROM policy_fact
    UNION ALL
    SELECT 'vehicle_type', vehicle_type, * FROM policy_fact
    UNION ALL
    SELECT 'vehicle_age', vehicle_age_group, * FROM policy_fact
    UNION ALL
    SELECT 'county', county, * FROM policy_fact
    UNION ALL
    SELECT 'driver_vehicle', driver_age_group || ' / ' || vehicle_type, * FROM policy_fact
)
SELECT dimension, group_name, COUNT(*) AS policy_terms,
       SUM(exposure_years) AS policy_years,
       SUM(claim_count) AS claims,
       SUM(CASE WHEN claim_count > 0 THEN 1 ELSE 0 END) AS policies_with_claim,
       SUM(total_paid_usd) AS total_paid_usd,
       1.0 * SUM(claim_count) / NULLIF(SUM(exposure_years), 0) AS frequency_per_policy_year,
       SUM(total_paid_usd) / NULLIF(SUM(claim_count), 0) AS average_paid_per_claim_usd,
       SUM(total_paid_usd) / NULLIF(SUM(exposure_years), 0) AS annual_expected_cost_usd,
       SUM(total_paid_usd) / NULLIF(COUNT(*), 0) AS observed_term_cost_usd,
       1.0 * SUM(CASE WHEN claim_count > 0 THEN 1 ELSE 0 END) / COUNT(*) AS observed_term_claim_probability
FROM groups
GROUP BY dimension, group_name
ORDER BY dimension, group_name;


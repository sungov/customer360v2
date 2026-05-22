USE DATABASE CUSTOMER360_V2;

CREATE OR REPLACE PROCEDURE GOLD.REFRESH_GOLDEN_CUSTOMER_PROFILE()
RETURNS STRING
LANGUAGE SQL
AS
$$
BEGIN
  CREATE OR REPLACE TEMP TABLE TMP_FACT_SUMMARY AS
  SELECT x.golden_customer_id,
         COUNT(DISTINCT s.stay_id) AS total_stays,
         COALESCE(SUM(s.revenue_amount),0) AS stay_spend,
         MAX(s.checkout_date) AS last_stay_date,
         0 AS total_spa_services,
         0 AS spa_spend,
         0 AS total_engagements,
         NULL::DATE AS last_engagement_date
  FROM IDENTITY.IDENTITY_CROSSWALK x
  JOIN GOLD.FACT_STAY s ON x.source_system=s.source_system AND x.source_customer_id=s.source_customer_id AND x.active_flag
  GROUP BY x.golden_customer_id
  UNION ALL
  SELECT x.golden_customer_id, 0, 0, NULL::DATE, COUNT(DISTINCT sp.service_id), COALESCE(SUM(sp.amount),0), 0, NULL::DATE
  FROM IDENTITY.IDENTITY_CROSSWALK x
  JOIN GOLD.FACT_SPA_SERVICE sp ON x.source_system=sp.source_system AND x.source_customer_id=sp.source_customer_id AND x.active_flag
  GROUP BY x.golden_customer_id
  UNION ALL
  SELECT x.golden_customer_id, 0, 0, NULL::DATE, 0, 0, COUNT(DISTINCT e.event_id), MAX(TO_DATE(e.event_timestamp))
  FROM IDENTITY.IDENTITY_CROSSWALK x
  JOIN GOLD.FACT_ENGAGEMENT_EVENT e ON x.source_system=e.source_system AND x.source_customer_id=e.source_customer_id AND x.active_flag
  GROUP BY x.golden_customer_id;

  CREATE OR REPLACE TEMP TABLE TMP_FACT_ROLLUP AS
  SELECT golden_customer_id,
         SUM(total_stays) total_stays,
         SUM(stay_spend + spa_spend) total_spend,
         SUM(total_spa_services) total_spa_services,
         SUM(total_engagements) total_engagements,
         MAX(GREATEST(COALESCE(last_stay_date,'1900-01-01'), COALESCE(last_engagement_date,'1900-01-01'))) AS last_activity_date
  FROM TMP_FACT_SUMMARY
  GROUP BY golden_customer_id;

  CREATE OR REPLACE TEMP TABLE TMP_LINKS AS
  SELECT golden_customer_id,
         ARRAY_AGG(source_system || ':' || source_customer_id) AS linked_source_keys,
         ARRAY_AGG(DISTINCT source_system) AS linked_source_systems
  FROM IDENTITY.IDENTITY_CROSSWALK
  WHERE active_flag
  GROUP BY golden_customer_id;

  TRUNCATE TABLE GOLD.GOLDEN_CUSTOMER_PROFILE;
  INSERT INTO GOLD.GOLDEN_CUSTOMER_PROFILE
  SELECT g.golden_customer_id, g.first_name, g.last_name, g.email, g.phone,
         l.linked_source_keys, l.linked_source_systems,
         COALESCE(f.total_stays,0), COALESCE(f.total_spend,0), COALESCE(f.total_spa_services,0), COALESCE(f.total_engagements,0), f.last_activity_date,
         CASE WHEN COALESCE(f.total_spa_services,0) > 0 THEN 'Offer premium spa package'
              WHEN COALESCE(f.total_stays,0) > 0 THEN 'Offer wellness retreat package'
              ELSE 'Send welcome campaign' END AS top_recommendation,
         CASE WHEN COALESCE(f.total_spa_services,0) > 0 THEN 'Customer has prior spa service history'
              WHEN COALESCE(f.total_stays,0) > 0 THEN 'Customer has prior stay history'
              ELSE 'No recent activity found' END AS recommendation_reason,
         CURRENT_TIMESTAMP()
  FROM GOLD.GOLDEN_CUSTOMER g
  LEFT JOIN TMP_LINKS l ON g.golden_customer_id=l.golden_customer_id
  LEFT JOIN TMP_FACT_ROLLUP f ON g.golden_customer_id=f.golden_customer_id;

  RETURN 'Refreshed GOLD.GOLDEN_CUSTOMER_PROFILE';
END;
$$;

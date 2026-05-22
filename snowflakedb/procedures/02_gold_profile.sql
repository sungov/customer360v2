USE DATABASE CUSTOMER360_V2;

CREATE OR REPLACE PROCEDURE GOLD.REFRESH_GOLDEN_CUSTOMER_PROFILE()
RETURNS STRING
LANGUAGE SQL
AS
$$
BEGIN

  CREATE OR REPLACE TABLE GOLD.GOLDEN_CUSTOMER_PROFILE AS
  SELECT
      g.golden_customer_id,
      g.first_name,
      g.last_name,
      g.email,
      g.phone,

      ARRAY_AGG(DISTINCT x.source_system || ':' || x.source_customer_id) AS linked_source_keys,
      ARRAY_AGG(DISTINCT x.source_system) AS linked_source_systems,

      0 AS total_stays,
      0::NUMBER(18,2) AS total_spend,
      0 AS total_spa_services,
      0 AS total_engagements,
      NULL::DATE AS last_activity_date,

      CURRENT_TIMESTAMP() AS refreshed_at

  FROM GOLD.GOLDEN_CUSTOMER g
  LEFT JOIN IDENTITY.IDENTITY_CROSSWALK x
    ON g.golden_customer_id = x.golden_customer_id
   AND x.active_flag = TRUE
  WHERE g.status = 'ACTIVE'
  GROUP BY
      g.golden_customer_id,
      g.first_name,
      g.last_name,
      g.email,
      g.phone;

  RETURN 'Refreshed GOLD.GOLDEN_CUSTOMER_PROFILE';

END;
$$;
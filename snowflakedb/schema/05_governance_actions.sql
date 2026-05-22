USE DATABASE CUSTOMER360_V2;

-- ============================================================
-- Customer360 v2 Governance & Stewardship Patch
-- Adds event history, rejection registry, stewardship actions,
-- unmerge/dissolve procedures, and dashboard views.
-- ============================================================

CREATE SCHEMA IF NOT EXISTS IDENTITY;
CREATE SCHEMA IF NOT EXISTS CONFIG;
CREATE SCHEMA IF NOT EXISTS GOLD;

CREATE TABLE IF NOT EXISTS IDENTITY.MATCH_REJECTION_REGISTRY (
  rejection_id STRING DEFAULT UUID_STRING(),
  left_source_system STRING,
  left_source_customer_id STRING,
  right_source_system STRING,
  right_source_customer_id STRING,
  reason STRING,
  rejected_by STRING,
  rejected_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
  active_flag BOOLEAN DEFAULT TRUE
);

CREATE TABLE IF NOT EXISTS IDENTITY.IDENTITY_EVENT_LOG (
  event_id STRING DEFAULT UUID_STRING(),
  event_type STRING,
  golden_customer_id STRING,
  source_system STRING,
  source_customer_id STRING,
  related_source_system STRING,
  related_source_customer_id STRING,
  match_score NUMBER(8,4),
  match_reason STRING,
  rule_version_id STRING,
  actor STRING,
  reason STRING,
  payload VARIANT,
  created_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- Keep old MERGE_EVENT_LOG usable too. It already exists in v2, but this view-like table is richer.

CREATE OR REPLACE VIEW IDENTITY.V_CURRENT_CROSSWALK AS
SELECT *
FROM IDENTITY.IDENTITY_CROSSWALK
WHERE active_flag = TRUE;

CREATE OR REPLACE VIEW IDENTITY.V_DECISION_HISTORY AS
SELECT
  created_at,
  event_type,
  golden_customer_id,
  source_system,
  source_customer_id,
  related_source_system,
  related_source_customer_id,
  match_score,
  match_reason,
  actor,
  reason,
  payload
FROM IDENTITY.IDENTITY_EVENT_LOG;

CREATE OR REPLACE VIEW GOLD.V_DASHBOARD_METRICS AS
SELECT
  (SELECT COUNT(*) FROM IDENTITY.SOURCE_CUSTOMER WHERE active_flag = TRUE) AS source_records,
  (SELECT COUNT(*) FROM GOLD.GOLDEN_CUSTOMER WHERE status = 'ACTIVE') AS golden_customers,
  (SELECT COUNT(*) FROM IDENTITY.IDENTITY_CROSSWALK WHERE active_flag = TRUE) AS active_links,
  (SELECT COUNT(*) FROM IDENTITY.STEWARDSHIP_QUEUE WHERE status IN ('OPEN','PENDING')) AS open_stewardship,
  (SELECT COUNT(*) FROM IDENTITY.STEWARDSHIP_QUEUE WHERE status IN ('APPROVED','RESOLVED') AND resolution = 'APPROVE') AS approved_matches,
  (SELECT COUNT(*) FROM IDENTITY.STEWARDSHIP_QUEUE WHERE status IN ('REJECTED','RESOLVED') AND resolution = 'REJECT') AS rejected_matches,
  (SELECT COUNT(*) FROM PROCESSING.BATCH_CONTROL) AS total_batches,
  (SELECT COUNT(*) FROM PROCESSING.BATCH_CONTROL WHERE status = 'COMPLETE') AS complete_batches,
  (SELECT COUNT(*) FROM PROCESSING.BATCH_CONTROL WHERE status = 'ERROR') AS failed_batches;

CREATE OR REPLACE VIEW GOLD.V_CLUSTER_SIZE_DISTRIBUTION AS
SELECT linked_count, COUNT(*) AS golden_customer_count
FROM (
  SELECT golden_customer_id, COUNT(*) AS linked_count
  FROM IDENTITY.IDENTITY_CROSSWALK
  WHERE active_flag = TRUE
  GROUP BY golden_customer_id
)
GROUP BY linked_count;

CREATE OR REPLACE VIEW GOLD.V_SOURCE_OVERLAP AS
SELECT
  golden_customer_id,
  ARRAY_AGG(DISTINCT source_system) AS source_systems,
  COUNT(DISTINCT source_system) AS source_system_count,
  COUNT(*) AS source_record_count
FROM IDENTITY.IDENTITY_CROSSWALK
WHERE active_flag = TRUE
GROUP BY golden_customer_id;

CREATE OR REPLACE VIEW IDENTITY.V_MATCH_CONFIDENCE AS
SELECT
  COALESCE(link_type, 'UNKNOWN') AS match_type,
  ROUND(confidence, 2) AS score_bucket,
  COUNT(*) AS record_count
FROM IDENTITY.IDENTITY_CROSSWALK
WHERE active_flag = TRUE
GROUP BY COALESCE(link_type, 'UNKNOWN'), ROUND(confidence, 2);

-- ============================================================
-- Approve match from stewardship queue.
-- Uses existing right-side golden customer if available. Otherwise creates a new golden from left source.
-- Then links both records to the same golden ID.
-- ============================================================
CREATE OR REPLACE PROCEDURE IDENTITY.APPROVE_MATCH(P_QUEUE_ID STRING, P_NOTE STRING)
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
  v_left_src STRING;
  v_left_id STRING;
  v_right_src STRING;
  v_right_id STRING;
  v_score FLOAT;
  v_reason STRING;
  v_golden STRING;
  v_rule STRING;
BEGIN
  SELECT left_source_system, left_source_customer_id, right_source_system, right_source_customer_id, score, reason
    INTO :v_left_src, :v_left_id, :v_right_src, :v_right_id, :v_score, :v_reason
  FROM IDENTITY.STEWARDSHIP_QUEUE
  WHERE queue_id = :P_QUEUE_ID;

  SELECT golden_customer_id INTO :v_golden
  FROM IDENTITY.IDENTITY_CROSSWALK
  WHERE active_flag = TRUE
    AND source_system = :v_right_src
    AND source_customer_id = :v_right_id
  LIMIT 1;

  IF (v_golden IS NULL) THEN
    SELECT golden_customer_id INTO :v_golden
    FROM IDENTITY.IDENTITY_CROSSWALK
    WHERE active_flag = TRUE
      AND source_system = :v_left_src
      AND source_customer_id = :v_left_id
    LIMIT 1;
  END IF;

  IF (v_golden IS NULL) THEN
    v_golden := UUID_STRING();
    INSERT INTO GOLD.GOLDEN_CUSTOMER (
      golden_customer_id, first_name, last_name, email, phone, dob, address_line1, city, state, postal_code, country, loyalty_id, status
    )
    SELECT :v_golden, first_name, last_name, email, phone, dob, address_line1, city, state, postal_code, country, loyalty_id, 'ACTIVE'
    FROM IDENTITY.SOURCE_CUSTOMER
    WHERE source_system = :v_left_src AND source_customer_id = :v_left_id
    LIMIT 1;
  END IF;

  UPDATE IDENTITY.IDENTITY_CROSSWALK
     SET active_flag = FALSE, updated_at = CURRENT_TIMESTAMP()
   WHERE active_flag = TRUE
     AND ((source_system = :v_left_src AND source_customer_id = :v_left_id)
       OR (source_system = :v_right_src AND source_customer_id = :v_right_id));

  INSERT INTO IDENTITY.IDENTITY_CROSSWALK (
    source_system, source_customer_id, source_record_uid, golden_customer_id, link_type, confidence, rule_version_id, active_flag
  )
  SELECT source_system, source_customer_id, source_record_uid, :v_golden, 'MANUAL_APPROVE', COALESCE(:v_score, 1.0), NULL, TRUE
  FROM IDENTITY.SOURCE_CUSTOMER
  WHERE (source_system = :v_left_src AND source_customer_id = :v_left_id)
     OR (source_system = :v_right_src AND source_customer_id = :v_right_id);

  UPDATE IDENTITY.STEWARDSHIP_QUEUE
     SET status = 'RESOLVED', resolution = 'APPROVE', resolved_at = CURRENT_TIMESTAMP(), resolved_by = CURRENT_USER()
   WHERE queue_id = :P_QUEUE_ID;

  INSERT INTO IDENTITY.IDENTITY_EVENT_LOG (
    event_type, golden_customer_id, source_system, source_customer_id, related_source_system,
    related_source_customer_id, match_score, match_reason, actor, reason, payload
  )
  SELECT 'APPROVE_MATCH', :v_golden, :v_left_src, :v_left_id, :v_right_src, :v_right_id,
         :v_score, :v_reason, CURRENT_USER(), :P_NOTE, OBJECT_CONSTRUCT('queue_id', :P_QUEUE_ID);

  CALL GOLD.REFRESH_GOLDEN_CUSTOMER_PROFILE();

  RETURN OBJECT_CONSTRUCT('status','success','action','APPROVE','golden_customer_id',:v_golden,'queue_id',:P_QUEUE_ID);
END;
$$;

-- ============================================================
-- Reject match from stewardship queue.
-- Adds pair to rejection registry and writes event history.
-- ============================================================
CREATE OR REPLACE PROCEDURE IDENTITY.REJECT_MATCH(P_QUEUE_ID STRING, P_NOTE STRING)
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
  v_left_src STRING;
  v_left_id STRING;
  v_right_src STRING;
  v_right_id STRING;
  v_score FLOAT;
  v_reason STRING;
BEGIN
  SELECT left_source_system, left_source_customer_id, right_source_system, right_source_customer_id, score, reason
    INTO :v_left_src, :v_left_id, :v_right_src, :v_right_id, :v_score, :v_reason
  FROM IDENTITY.STEWARDSHIP_QUEUE
  WHERE queue_id = :P_QUEUE_ID;

  INSERT INTO IDENTITY.MATCH_REJECTION_REGISTRY (
    left_source_system, left_source_customer_id, right_source_system, right_source_customer_id, reason, rejected_by
  )
  VALUES (:v_left_src, :v_left_id, :v_right_src, :v_right_id, :P_NOTE, CURRENT_USER());

  UPDATE IDENTITY.STEWARDSHIP_QUEUE
     SET status = 'RESOLVED', resolution = 'REJECT', resolved_at = CURRENT_TIMESTAMP(), resolved_by = CURRENT_USER()
   WHERE queue_id = :P_QUEUE_ID;

  INSERT INTO IDENTITY.IDENTITY_EVENT_LOG (
    event_type, source_system, source_customer_id, related_source_system,
    related_source_customer_id, match_score, match_reason, actor, reason, payload
  )
  SELECT 'REJECT_MATCH', :v_left_src, :v_left_id, :v_right_src, :v_right_id,
         :v_score, :v_reason, CURRENT_USER(), :P_NOTE, OBJECT_CONSTRUCT('queue_id', :P_QUEUE_ID);

  RETURN OBJECT_CONSTRUCT('status','success','action','REJECT','queue_id',:P_QUEUE_ID);
END;
$$;

-- ============================================================
-- Unmerge/eject one source record from a golden cluster.
-- Creates a new golden ID for the ejected source record.
-- ============================================================
CREATE OR REPLACE PROCEDURE IDENTITY.UNMERGE_SOURCE_RECORD(
  P_GOLDEN_CUSTOMER_ID STRING,
  P_SOURCE_SYSTEM STRING,
  P_SOURCE_CUSTOMER_ID STRING,
  P_REASON STRING
)
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
  v_new_golden STRING DEFAULT UUID_STRING();
BEGIN
  UPDATE IDENTITY.IDENTITY_CROSSWALK
     SET active_flag = FALSE, updated_at = CURRENT_TIMESTAMP()
   WHERE active_flag = TRUE
     AND golden_customer_id = :P_GOLDEN_CUSTOMER_ID
     AND source_system = :P_SOURCE_SYSTEM
     AND source_customer_id = :P_SOURCE_CUSTOMER_ID;

  INSERT INTO GOLD.GOLDEN_CUSTOMER (
    golden_customer_id, first_name, last_name, email, phone, dob, address_line1, city, state, postal_code, country, loyalty_id, status
  )
  SELECT :v_new_golden, first_name, last_name, email, phone, dob, address_line1, city, state, postal_code, country, loyalty_id, 'ACTIVE'
  FROM IDENTITY.SOURCE_CUSTOMER
  WHERE source_system = :P_SOURCE_SYSTEM AND source_customer_id = :P_SOURCE_CUSTOMER_ID
  LIMIT 1;

  INSERT INTO IDENTITY.IDENTITY_CROSSWALK (
    source_system, source_customer_id, source_record_uid, golden_customer_id, link_type, confidence, rule_version_id, active_flag
  )
  SELECT source_system, source_customer_id, source_record_uid, :v_new_golden, 'MANUAL_UNMERGE', 1.0, NULL, TRUE
  FROM IDENTITY.SOURCE_CUSTOMER
  WHERE source_system = :P_SOURCE_SYSTEM AND source_customer_id = :P_SOURCE_CUSTOMER_ID;

  INSERT INTO IDENTITY.IDENTITY_EVENT_LOG (
    event_type, golden_customer_id, source_system, source_customer_id, actor, reason,
    payload
  )
  SELECT 'UNMERGE_SOURCE_RECORD', :P_GOLDEN_CUSTOMER_ID, :P_SOURCE_SYSTEM, :P_SOURCE_CUSTOMER_ID,
         CURRENT_USER(), :P_REASON, OBJECT_CONSTRUCT('new_golden_customer_id', :v_new_golden);

  CALL GOLD.REFRESH_GOLDEN_CUSTOMER_PROFILE();

  RETURN OBJECT_CONSTRUCT('status','success','old_golden_customer_id',:P_GOLDEN_CUSTOMER_ID,'new_golden_customer_id',:v_new_golden);
END;
$$;

-- ============================================================
-- Dissolve full cluster: every source record gets its own golden ID.
-- ============================================================
CREATE OR REPLACE PROCEDURE IDENTITY.DISSOLVE_GOLDEN_CLUSTER(
  P_GOLDEN_CUSTOMER_ID STRING,
  P_REASON STRING
)
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
  v_count NUMBER DEFAULT 0;
BEGIN
  CREATE OR REPLACE TEMP TABLE TMP_DISSOLVE_MEMBERS AS
  SELECT x.source_system, x.source_customer_id, sc.source_record_uid,
         UUID_STRING() AS new_golden_customer_id,
         sc.first_name, sc.last_name, sc.email, sc.phone, sc.dob,
         sc.address_line1, sc.city, sc.state, sc.postal_code, sc.country, sc.loyalty_id
  FROM IDENTITY.IDENTITY_CROSSWALK x
  JOIN IDENTITY.SOURCE_CUSTOMER sc
    ON x.source_system = sc.source_system
   AND x.source_customer_id = sc.source_customer_id
  WHERE x.active_flag = TRUE
    AND x.golden_customer_id = :P_GOLDEN_CUSTOMER_ID;

  SELECT COUNT(*) INTO :v_count FROM TMP_DISSOLVE_MEMBERS;

  UPDATE IDENTITY.IDENTITY_CROSSWALK
     SET active_flag = FALSE, updated_at = CURRENT_TIMESTAMP()
   WHERE active_flag = TRUE
     AND golden_customer_id = :P_GOLDEN_CUSTOMER_ID;

  INSERT INTO GOLD.GOLDEN_CUSTOMER (
    golden_customer_id, first_name, last_name, email, phone, dob, address_line1, city, state, postal_code, country, loyalty_id, status
  )
  SELECT new_golden_customer_id, first_name, last_name, email, phone, dob, address_line1, city, state, postal_code, country, loyalty_id, 'ACTIVE'
  FROM TMP_DISSOLVE_MEMBERS;

  INSERT INTO IDENTITY.IDENTITY_CROSSWALK (
    source_system, source_customer_id, source_record_uid, golden_customer_id, link_type, confidence, rule_version_id, active_flag
  )
  SELECT source_system, source_customer_id, source_record_uid, new_golden_customer_id, 'MANUAL_DISSOLVE', 1.0, NULL, TRUE
  FROM TMP_DISSOLVE_MEMBERS;

  INSERT INTO IDENTITY.IDENTITY_EVENT_LOG (
    event_type, golden_customer_id, actor, reason, payload
  )
  SELECT 'DISSOLVE_GOLDEN_CLUSTER', :P_GOLDEN_CUSTOMER_ID, CURRENT_USER(), :P_REASON,
         OBJECT_CONSTRUCT('member_count', :v_count);

  CALL GOLD.REFRESH_GOLDEN_CUSTOMER_PROFILE();

  RETURN OBJECT_CONSTRUCT('status','success','old_golden_customer_id',:P_GOLDEN_CUSTOMER_ID,'members_dissolved',:v_count);
END;
$$;

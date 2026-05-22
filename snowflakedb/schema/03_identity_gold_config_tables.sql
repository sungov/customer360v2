USE DATABASE CUSTOMER360_V2;

CREATE OR REPLACE TABLE IDENTITY.SOURCE_CUSTOMER (
  source_record_uid STRING DEFAULT UUID_STRING(), batch_id STRING, source_system STRING, source_customer_id STRING,
  first_name STRING, last_name STRING, email STRING, phone STRING, dob DATE, address_line1 STRING, city STRING, state STRING, postal_code STRING, country STRING, loyalty_id STRING,
  raw_record_id STRING, active_flag BOOLEAN DEFAULT TRUE, created_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(), updated_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);
CREATE OR REPLACE TABLE IDENTITY.SOURCE_CUSTOMER_KEYS (
  source_record_uid STRING, source_system STRING, source_customer_id STRING,
  normalized_email STRING, normalized_phone STRING, normalized_first_name STRING, normalized_last_name STRING, normalized_full_name STRING,
  dob DATE, postal_code STRING, loyalty_id STRING, blocking_email_domain STRING, blocking_phone_last4 STRING, blocking_name_dob STRING,
  created_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);
CREATE OR REPLACE TABLE IDENTITY.SOURCE_DEDUPE_GROUP (
  dedupe_group_id STRING DEFAULT UUID_STRING(), source_system STRING, rule_version_id STRING, created_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);
CREATE OR REPLACE TABLE IDENTITY.SOURCE_DEDUPE_MEMBER (
  dedupe_group_id STRING, source_system STRING, source_customer_id STRING, source_record_uid STRING, confidence NUMBER(5,4), rule_name STRING
);
CREATE OR REPLACE TABLE GOLD.GOLDEN_CUSTOMER (
  golden_customer_id STRING PRIMARY KEY, rule_version_id STRING,
  first_name STRING, last_name STRING, email STRING, phone STRING, dob DATE, address_line1 STRING, city STRING, state STRING, postal_code STRING, country STRING, loyalty_id STRING,
  status STRING DEFAULT 'ACTIVE', created_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(), updated_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);
CREATE OR REPLACE TABLE IDENTITY.IDENTITY_CROSSWALK (
  source_system STRING, source_customer_id STRING, source_record_uid STRING, golden_customer_id STRING,
  link_type STRING, confidence NUMBER(5,4), rule_version_id STRING, active_flag BOOLEAN DEFAULT TRUE,
  linked_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(), updated_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);
CREATE OR REPLACE TABLE IDENTITY.MATCH_CANDIDATE (
  match_run_id STRING, left_source_system STRING, left_source_customer_id STRING, right_source_system STRING, right_source_customer_id STRING,
  candidate_type STRING, score NUMBER(5,4), reason STRING, decision STRING, created_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);
CREATE OR REPLACE TABLE IDENTITY.MATCH_DECISION (
  match_run_id STRING, left_source_system STRING, left_source_customer_id STRING, right_source_system STRING, right_source_customer_id STRING,
  decision STRING, score NUMBER(5,4), rule_version_id STRING, decided_by STRING DEFAULT 'SYSTEM', decided_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(), notes STRING
);
CREATE OR REPLACE TABLE IDENTITY.STEWARDSHIP_QUEUE (
  queue_id STRING DEFAULT UUID_STRING(), match_run_id STRING, left_source_system STRING, left_source_customer_id STRING, right_source_system STRING, right_source_customer_id STRING,
  score NUMBER(5,4), reason STRING, status STRING DEFAULT 'OPEN', created_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(), resolved_at TIMESTAMP_NTZ, resolved_by STRING, resolution STRING
);
CREATE OR REPLACE TABLE IDENTITY.MERGE_EVENT_LOG (
  event_id STRING DEFAULT UUID_STRING(), event_type STRING, golden_customer_id STRING, source_system STRING, source_customer_id STRING,
  rule_version_id STRING, actor STRING, details VARIANT, created_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE TABLE CONFIG.RULE_SET (
  rule_version_id STRING, rule_set_name STRING, rule_scope STRING, source_system_left STRING, source_system_right STRING,
  auto_match_threshold NUMBER(5,4), review_threshold NUMBER(5,4), status STRING, created_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);
CREATE OR REPLACE TABLE CONFIG.RULE_CONDITION (
  rule_version_id STRING, rule_name STRING, condition_order NUMBER, field_name STRING, match_type STRING, weight NUMBER(8,4), enabled BOOLEAN DEFAULT TRUE
);
CREATE OR REPLACE TABLE CONFIG.SURVIVORSHIP_RULE (
  rule_version_id STRING, field_name STRING, source_priority ARRAY, default_strategy STRING
);

CREATE OR REPLACE TABLE GOLD.FACT_STAY (
  stay_id STRING, source_system STRING, source_customer_id STRING, property_code STRING, checkin_date DATE, checkout_date DATE, room_type STRING, nights NUMBER, revenue_amount NUMBER(18,2), currency STRING, batch_id STRING, loaded_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);
CREATE OR REPLACE TABLE GOLD.FACT_SPA_SERVICE (
  service_id STRING, source_system STRING, source_customer_id STRING, service_date DATE, service_type STRING, provider_id STRING, amount NUMBER(18,2), currency STRING, batch_id STRING, loaded_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);
CREATE OR REPLACE TABLE GOLD.FACT_TRANSACTION (
  transaction_id STRING, source_system STRING, source_customer_id STRING, transaction_date DATE, category STRING, amount NUMBER(18,2), currency STRING, batch_id STRING, loaded_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);
CREATE OR REPLACE TABLE GOLD.FACT_ENGAGEMENT_EVENT (
  event_id STRING, source_system STRING, source_customer_id STRING, event_timestamp TIMESTAMP_NTZ, channel STRING, campaign_name STRING, event_type STRING, batch_id STRING, loaded_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);
CREATE OR REPLACE TABLE GOLD.FACT_RECOMMENDATION (
  recommendation_id STRING, expected_person_id STRING, recommendation STRING, reason STRING, priority STRING, created_at DATE, batch_id STRING, loaded_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE TABLE GOLD.GOLDEN_CUSTOMER_PROFILE (
  golden_customer_id STRING, first_name STRING, last_name STRING, email STRING, phone STRING, linked_source_keys ARRAY, linked_source_systems ARRAY,
  total_stays NUMBER, total_spend NUMBER(18,2), total_spa_services NUMBER, total_engagements NUMBER, last_activity_date DATE,
  top_recommendation STRING, recommendation_reason STRING, refreshed_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

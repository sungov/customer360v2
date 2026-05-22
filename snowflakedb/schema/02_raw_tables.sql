USE DATABASE CUSTOMER360_V2;

CREATE OR REPLACE TABLE PROCESSING.BATCH_CONTROL (
  batch_id STRING PRIMARY KEY,
  source_system STRING,
  entity_type STRING,
  file_name STRING,
  load_type STRING,
  status STRING DEFAULT 'LOADED',
  record_count NUMBER,
  created_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
  started_at TIMESTAMP_NTZ,
  completed_at TIMESTAMP_NTZ,
  error_message STRING
);

CREATE OR REPLACE TABLE RAW.OPERA_CUSTOMERS (
  raw_record_id STRING DEFAULT UUID_STRING(), batch_id STRING, source_file_name STRING,
  source_customer_id STRING, expected_person_id STRING, first_name STRING, last_name STRING, email STRING, phone STRING, dob DATE,
  address_line1 STRING, city STRING, state STRING, postal_code STRING, country STRING, loyalty_id STRING,
  created_at TIMESTAMP_NTZ, updated_at TIMESTAMP_NTZ,
  record_hash STRING, process_status STRING DEFAULT 'NEW', loaded_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(), processed_at TIMESTAMP_NTZ, error_message STRING
);
CREATE OR REPLACE TABLE RAW.B4T_CUSTOMERS LIKE RAW.OPERA_CUSTOMERS;
CREATE OR REPLACE TABLE RAW.BRAZE_PROFILES LIKE RAW.OPERA_CUSTOMERS;
CREATE OR REPLACE TABLE RAW.APP_USERS LIKE RAW.OPERA_CUSTOMERS;

CREATE OR REPLACE TABLE RAW.OPERA_STAYS (
  raw_record_id STRING DEFAULT UUID_STRING(), batch_id STRING, source_file_name STRING,
  stay_id STRING, source_system STRING, source_customer_id STRING, expected_person_id STRING, property_code STRING,
  checkin_date DATE, checkout_date DATE, room_type STRING, nights NUMBER, revenue_amount NUMBER(18,2), currency STRING,
  process_status STRING DEFAULT 'NEW', loaded_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(), processed_at TIMESTAMP_NTZ, error_message STRING
);
CREATE OR REPLACE TABLE RAW.B4T_SPA_SERVICES (
  raw_record_id STRING DEFAULT UUID_STRING(), batch_id STRING, source_file_name STRING,
  service_id STRING, source_system STRING, source_customer_id STRING, expected_person_id STRING, service_date DATE,
  service_type STRING, provider_id STRING, amount NUMBER(18,2), currency STRING,
  process_status STRING DEFAULT 'NEW', loaded_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(), processed_at TIMESTAMP_NTZ, error_message STRING
);
CREATE OR REPLACE TABLE RAW.TRANSACTIONS (
  raw_record_id STRING DEFAULT UUID_STRING(), batch_id STRING, source_file_name STRING,
  transaction_id STRING, source_system STRING, source_customer_id STRING, expected_person_id STRING, transaction_date DATE,
  category STRING, amount NUMBER(18,2), currency STRING,
  process_status STRING DEFAULT 'NEW', loaded_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(), processed_at TIMESTAMP_NTZ, error_message STRING
);
CREATE OR REPLACE TABLE RAW.BRAZE_ENGAGEMENT_EVENTS (
  raw_record_id STRING DEFAULT UUID_STRING(), batch_id STRING, source_file_name STRING,
  event_id STRING, source_system STRING, source_customer_id STRING, expected_person_id STRING, event_timestamp TIMESTAMP_NTZ,
  channel STRING, campaign_name STRING, event_type STRING,
  process_status STRING DEFAULT 'NEW', loaded_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(), processed_at TIMESTAMP_NTZ, error_message STRING
);
CREATE OR REPLACE TABLE RAW.RECOMMENDATIONS (
  raw_record_id STRING DEFAULT UUID_STRING(), batch_id STRING, source_file_name STRING,
  expected_person_id STRING, recommendation_id STRING, recommendation STRING, reason STRING, priority STRING, created_at DATE,
  process_status STRING DEFAULT 'NEW', loaded_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(), processed_at TIMESTAMP_NTZ, error_message STRING
);

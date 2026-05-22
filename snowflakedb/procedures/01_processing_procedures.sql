USE DATABASE CUSTOMER360_V2;

CREATE OR REPLACE PROCEDURE PROCESSING.LOAD_RAW_CUSTOMERS_TO_IDENTITY(P_BATCH_ID STRING)
RETURNS STRING
LANGUAGE SQL
AS
$$
BEGIN
  INSERT INTO IDENTITY.SOURCE_CUSTOMER(batch_id, source_system, source_customer_id, first_name, last_name, email, phone, dob, address_line1, city, state, postal_code, country, loyalty_id, raw_record_id)
  SELECT batch_id, 'OPERA', source_customer_id, first_name, last_name, email, phone, dob, address_line1, city, state, postal_code, country, loyalty_id, raw_record_id
  FROM RAW.OPERA_CUSTOMERS WHERE batch_id = P_BATCH_ID AND process_status = 'NEW';

  INSERT INTO IDENTITY.SOURCE_CUSTOMER(batch_id, source_system, source_customer_id, first_name, last_name, email, phone, dob, address_line1, city, state, postal_code, country, loyalty_id, raw_record_id)
  SELECT batch_id, 'B4T', source_customer_id, first_name, last_name, email, phone, dob, address_line1, city, state, postal_code, country, loyalty_id, raw_record_id
  FROM RAW.B4T_CUSTOMERS WHERE batch_id = P_BATCH_ID AND process_status = 'NEW';

  INSERT INTO IDENTITY.SOURCE_CUSTOMER(batch_id, source_system, source_customer_id, first_name, last_name, email, phone, dob, address_line1, city, state, postal_code, country, loyalty_id, raw_record_id)
  SELECT batch_id, 'BRAZE', source_customer_id, first_name, last_name, email, phone, dob, address_line1, city, state, postal_code, country, loyalty_id, raw_record_id
  FROM RAW.BRAZE_PROFILES WHERE batch_id = P_BATCH_ID AND process_status = 'NEW';

  INSERT INTO IDENTITY.SOURCE_CUSTOMER(batch_id, source_system, source_customer_id, first_name, last_name, email, phone, dob, address_line1, city, state, postal_code, country, loyalty_id, raw_record_id)
  SELECT batch_id, 'APP', source_customer_id, first_name, last_name, email, phone, dob, address_line1, city, state, postal_code, country, loyalty_id, raw_record_id
  FROM RAW.APP_USERS WHERE batch_id = P_BATCH_ID AND process_status = 'NEW';

  UPDATE RAW.OPERA_CUSTOMERS SET process_status='COMPLETE', processed_at=CURRENT_TIMESTAMP() WHERE batch_id=P_BATCH_ID AND process_status='NEW';
  UPDATE RAW.B4T_CUSTOMERS SET process_status='COMPLETE', processed_at=CURRENT_TIMESTAMP() WHERE batch_id=P_BATCH_ID AND process_status='NEW';
  UPDATE RAW.BRAZE_PROFILES SET process_status='COMPLETE', processed_at=CURRENT_TIMESTAMP() WHERE batch_id=P_BATCH_ID AND process_status='NEW';
  UPDATE RAW.APP_USERS SET process_status='COMPLETE', processed_at=CURRENT_TIMESTAMP() WHERE batch_id=P_BATCH_ID AND process_status='NEW';

  RETURN 'Loaded raw customers to identity for batch ' || P_BATCH_ID;
END;
$$;

CREATE OR REPLACE PROCEDURE IDENTITY.BUILD_SOURCE_CUSTOMER_KEYS(P_BATCH_ID STRING)
RETURNS STRING
LANGUAGE SQL
AS
$$
BEGIN
  DELETE FROM IDENTITY.SOURCE_CUSTOMER_KEYS WHERE source_record_uid IN (SELECT source_record_uid FROM IDENTITY.SOURCE_CUSTOMER WHERE batch_id = P_BATCH_ID);

  INSERT INTO IDENTITY.SOURCE_CUSTOMER_KEYS(
    source_record_uid, source_system, source_customer_id, normalized_email, normalized_phone,
    normalized_first_name, normalized_last_name, normalized_full_name, dob, postal_code, loyalty_id,
    blocking_email_domain, blocking_phone_last4, blocking_name_dob
  )
  SELECT
    source_record_uid,
    source_system,
    source_customer_id,
    LOWER(TRIM(email)) AS normalized_email,
    CASE WHEN phone IS NULL THEN NULL ELSE '+' || REGEXP_REPLACE(phone, '[^0-9]', '') END AS normalized_phone,
    LOWER(REGEXP_REPLACE(TRIM(first_name), '[^A-Za-z ]', '')) AS normalized_first_name,
    LOWER(REGEXP_REPLACE(TRIM(last_name), '[^A-Za-z ]', '')) AS normalized_last_name,
    LOWER(REGEXP_REPLACE(TRIM(COALESCE(first_name,'') || ' ' || COALESCE(last_name,'')), '[^A-Za-z ]', '')) AS normalized_full_name,
    dob,
    postal_code,
    loyalty_id,
    SPLIT_PART(LOWER(email), '@', 2),
    RIGHT(REGEXP_REPLACE(phone, '[^0-9]', ''), 4),
    LOWER(REGEXP_REPLACE(TRIM(COALESCE(first_name,'') || COALESCE(last_name,'')), '[^A-Za-z]', '')) || ':' || COALESCE(TO_VARCHAR(dob),'')
  FROM IDENTITY.SOURCE_CUSTOMER
  WHERE batch_id = P_BATCH_ID;

  RETURN 'Built keys for batch ' || P_BATCH_ID;
END;
$$;

CREATE OR REPLACE PROCEDURE PROCESSING.LOAD_RAW_FACTS_TO_GOLD(P_BATCH_ID STRING)
RETURNS STRING
LANGUAGE SQL
AS
$$
BEGIN
  INSERT INTO GOLD.FACT_STAY(stay_id, source_system, source_customer_id, property_code, checkin_date, checkout_date, room_type, nights, revenue_amount, currency, batch_id)
  SELECT stay_id, 'OPERA', source_customer_id, property_code, checkin_date, checkout_date, room_type, nights, revenue_amount, currency, batch_id
  FROM RAW.OPERA_STAYS WHERE batch_id = P_BATCH_ID AND process_status = 'NEW';

  INSERT INTO GOLD.FACT_SPA_SERVICE(service_id, source_system, source_customer_id, service_date, service_type, provider_id, amount, currency, batch_id)
  SELECT service_id, COALESCE(source_system,'B4T'), source_customer_id, service_date, service_type, provider_id, amount, currency, batch_id
  FROM RAW.B4T_SPA_SERVICES WHERE batch_id = P_BATCH_ID AND process_status = 'NEW';

  INSERT INTO GOLD.FACT_TRANSACTION(transaction_id, source_system, source_customer_id, transaction_date, category, amount, currency, batch_id)
  SELECT transaction_id, source_system, source_customer_id, transaction_date, category, amount, currency, batch_id
  FROM RAW.TRANSACTIONS WHERE batch_id = P_BATCH_ID AND process_status = 'NEW';

  INSERT INTO GOLD.FACT_ENGAGEMENT_EVENT(event_id, source_system, source_customer_id, event_timestamp, channel, campaign_name, event_type, batch_id)
  SELECT event_id, source_system, source_customer_id, event_timestamp, channel, campaign_name, event_type, batch_id
  FROM RAW.BRAZE_ENGAGEMENT_EVENTS WHERE batch_id = P_BATCH_ID AND process_status = 'NEW';

  INSERT INTO GOLD.FACT_RECOMMENDATION(recommendation_id, expected_person_id, recommendation, reason, priority, created_at, batch_id)
  SELECT recommendation_id, expected_person_id, recommendation, reason, priority, created_at, batch_id
  FROM RAW.RECOMMENDATIONS WHERE batch_id = P_BATCH_ID AND process_status = 'NEW';

  UPDATE RAW.OPERA_STAYS SET process_status='COMPLETE', processed_at=CURRENT_TIMESTAMP() WHERE batch_id=P_BATCH_ID AND process_status='NEW';
  UPDATE RAW.B4T_SPA_SERVICES SET process_status='COMPLETE', processed_at=CURRENT_TIMESTAMP() WHERE batch_id=P_BATCH_ID AND process_status='NEW';
  UPDATE RAW.TRANSACTIONS SET process_status='COMPLETE', processed_at=CURRENT_TIMESTAMP() WHERE batch_id=P_BATCH_ID AND process_status='NEW';
  UPDATE RAW.BRAZE_ENGAGEMENT_EVENTS SET process_status='COMPLETE', processed_at=CURRENT_TIMESTAMP() WHERE batch_id=P_BATCH_ID AND process_status='NEW';
  UPDATE RAW.RECOMMENDATIONS SET process_status='COMPLETE', processed_at=CURRENT_TIMESTAMP() WHERE batch_id=P_BATCH_ID AND process_status='NEW';

  RETURN 'Loaded facts to gold for batch ' || P_BATCH_ID;
END;
$$;

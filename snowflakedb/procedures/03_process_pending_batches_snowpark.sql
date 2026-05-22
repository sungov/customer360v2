-- Customer360 v2 - Snowpark Python Stored Procedure
-- Procedure: PROCESSING.PROCESS_PENDING_BATCHES
-- This is a production-shaped starter. Adjust column names if your v2 schema differs.

CREATE OR REPLACE PROCEDURE PROCESSING.PROCESS_PENDING_BATCHES(MAX_BATCHES INTEGER DEFAULT 10)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'main'
EXECUTE AS OWNER
AS
$$
from __future__ import annotations

from datetime import datetime
from typing import Dict, List, Optional
from snowflake.snowpark import Session

CUSTOMER_RAW_TABLES = {
    "OPERA": "RAW.OPERA_CUSTOMERS",
    "B4T": "RAW.B4T_CUSTOMERS",
    "BRAZE": "RAW.BRAZE_PROFILES",
    "APP": "RAW.APP_USERS",
}

def q(s: str) -> str:
    return s.replace("'", "''") if s is not None else ""

def exec_sql(session: Session, sql: str):
    return session.sql(sql).collect()

def mark_batch(session: Session, batch_id: str, status: str, error: Optional[str] = None):
    if status == "PROCESSING":
        exec_sql(session, f"""
            UPDATE PROCESSING.BATCH_CONTROL
               SET status = 'PROCESSING',
                   started_at = COALESCE(started_at, CURRENT_TIMESTAMP()),
                   error_message = NULL
             WHERE batch_id = '{q(batch_id)}'
        """)
    elif status == "COMPLETE":
        exec_sql(session, f"""
            UPDATE PROCESSING.BATCH_CONTROL
               SET status = 'COMPLETE',
                   completed_at = CURRENT_TIMESTAMP(),
                   error_message = NULL
             WHERE batch_id = '{q(batch_id)}'
        """)
    elif status == "ERROR":
        exec_sql(session, f"""
            UPDATE PROCESSING.BATCH_CONTROL
               SET status = 'ERROR',
                   completed_at = CURRENT_TIMESTAMP(),
                   error_message = '{q(error or "")}'
             WHERE batch_id = '{q(batch_id)}'
        """)

def get_pending_customer_batches(session: Session, max_batches: int) -> List[Dict]:
    rows = exec_sql(session, f"""
        SELECT batch_id,
               source_system,
               entity_type,
               load_type,
               file_name
          FROM PROCESSING.BATCH_CONTROL
         WHERE status IN ('LOADED', 'NEW')
           AND UPPER(entity_type) IN ('CUSTOMER', 'PROFILE')
         ORDER BY created_at
         LIMIT {int(max_batches)}
    """)
    return [r.as_dict() for r in rows]

def load_raw_customers_to_identity(session: Session, batch_id: str, source_system: str):
    raw_table = CUSTOMER_RAW_TABLES.get(source_system.upper())
    if not raw_table:
        raise ValueError(f"No raw customer table mapped for source_system={source_system}")

    exec_sql(session, f"""
        MERGE INTO IDENTITY.SOURCE_CUSTOMER tgt
        USING (
            SELECT
                source_system,
                source_customer_id,
                first_name,
                last_name,
                email,
                phone,
                dob,
                address_line1,
                city,
                state,
                postal_code,
                country,
                loyalty_id,
                batch_id,
                raw_record_id
            FROM {raw_table}
            WHERE batch_id = '{q(batch_id)}'
              AND COALESCE(process_status, 'NEW') IN ('NEW', 'LOADED')
        ) src
        ON  tgt.source_system = src.source_system
        AND tgt.source_customer_id = src.source_customer_id
        WHEN MATCHED THEN UPDATE SET
            tgt.first_name = src.first_name,
            tgt.last_name = src.last_name,
            tgt.email = src.email,
            tgt.phone = src.phone,
            tgt.dob = src.dob,
            tgt.address_line1 = src.address_line1,
            tgt.city = src.city,
            tgt.state = src.state,
            tgt.postal_code = src.postal_code,
            tgt.country = src.country,
            tgt.loyalty_id = src.loyalty_id,
            tgt.last_seen_batch_id = src.batch_id,
            tgt.updated_at = CURRENT_TIMESTAMP()
        WHEN NOT MATCHED THEN INSERT (
            source_customer_uid,
            source_system,
            source_customer_id,
            first_name,
            last_name,
            email,
            phone,
            dob,
            address_line1,
            city,
            state,
            postal_code,
            country,
            loyalty_id,
            first_seen_batch_id,
            last_seen_batch_id,
            raw_record_id,
            created_at,
            updated_at,
            active_flag
        )
        VALUES (
            UUID_STRING(),
            src.source_system,
            src.source_customer_id,
            src.first_name,
            src.last_name,
            src.email,
            src.phone,
            src.dob,
            src.address_line1,
            src.city,
            src.state,
            src.postal_code,
            src.country,
            src.loyalty_id,
            src.batch_id,
            src.batch_id,
            src.raw_record_id,
            CURRENT_TIMESTAMP(),
            CURRENT_TIMESTAMP(),
            TRUE
        )
    """)

    exec_sql(session, f"""
        UPDATE {raw_table}
           SET process_status = 'PROCESSING'
         WHERE batch_id = '{q(batch_id)}'
           AND COALESCE(process_status, 'NEW') IN ('NEW', 'LOADED')
    """)

def build_customer_keys(session: Session, batch_id: str):
    exec_sql(session, f"""
        MERGE INTO IDENTITY.SOURCE_CUSTOMER_KEYS tgt
        USING (
            SELECT
                source_system,
                source_customer_id,
                LOWER(TRIM(email)) AS normalized_email,
                REGEXP_REPLACE(phone, '[^0-9]', '') AS normalized_phone,
                LOWER(TRIM(first_name)) AS normalized_first_name,
                LOWER(TRIM(last_name)) AS normalized_last_name,
                dob,
                LOWER(TRIM(postal_code)) AS normalized_postal_code,
                NULLIF(TRIM(loyalty_id), '') AS loyalty_id,
                CURRENT_TIMESTAMP() AS updated_at
            FROM IDENTITY.SOURCE_CUSTOMER
            WHERE last_seen_batch_id = '{q(batch_id)}'
              AND active_flag = TRUE
        ) src
        ON  tgt.source_system = src.source_system
        AND tgt.source_customer_id = src.source_customer_id
        WHEN MATCHED THEN UPDATE SET
            tgt.normalized_email = src.normalized_email,
            tgt.normalized_phone = src.normalized_phone,
            tgt.normalized_first_name = src.normalized_first_name,
            tgt.normalized_last_name = src.normalized_last_name,
            tgt.dob = src.dob,
            tgt.normalized_postal_code = src.normalized_postal_code,
            tgt.loyalty_id = src.loyalty_id,
            tgt.updated_at = src.updated_at
        WHEN NOT MATCHED THEN INSERT (
            source_system,
            source_customer_id,
            normalized_email,
            normalized_phone,
            normalized_first_name,
            normalized_last_name,
            dob,
            normalized_postal_code,
            loyalty_id,
            updated_at
        )
        VALUES (
            src.source_system,
            src.source_customer_id,
            src.normalized_email,
            src.normalized_phone,
            src.normalized_first_name,
            src.normalized_last_name,
            src.dob,
            src.normalized_postal_code,
            src.loyalty_id,
            src.updated_at
        )
    """)

def run_within_source_dedupe(session: Session, batch_id: str, source_system: str):
    exec_sql(session, f"""
        CREATE OR REPLACE TEMP TABLE TMP_SOURCE_DEDUPE AS
        SELECT
            k.source_system,
            k.source_customer_id,
            COALESCE(
                'LOYALTY:' || NULLIF(k.loyalty_id, ''),
                'EMAIL:' || NULLIF(k.normalized_email, ''),
                'PHONE:' || NULLIF(k.normalized_phone, ''),
                'SRC:' || k.source_system || ':' || k.source_customer_id
            ) AS dedupe_key
        FROM IDENTITY.SOURCE_CUSTOMER_KEYS k
        JOIN IDENTITY.SOURCE_CUSTOMER c
          ON c.source_system = k.source_system
         AND c.source_customer_id = k.source_customer_id
        WHERE c.last_seen_batch_id = '{q(batch_id)}'
          AND k.source_system = '{q(source_system)}'
    """)

    exec_sql(session, """
        CREATE OR REPLACE TEMP TABLE TMP_SOURCE_DEDUPE_GROUPS AS
        SELECT
            source_system,
            dedupe_key,
            MIN(source_customer_id) AS source_dedupe_group_id
        FROM TMP_SOURCE_DEDUPE
        GROUP BY source_system, dedupe_key
    """)

    exec_sql(session, f"""
        MERGE INTO IDENTITY.SOURCE_DEDUPE_MEMBER tgt
        USING (
            SELECT
                d.source_system,
                d.source_customer_id,
                g.source_dedupe_group_id,
                d.dedupe_key,
                CURRENT_TIMESTAMP() AS updated_at
            FROM TMP_SOURCE_DEDUPE d
            JOIN TMP_SOURCE_DEDUPE_GROUPS g
              ON d.source_system = g.source_system
             AND d.dedupe_key = g.dedupe_key
        ) src
        ON  tgt.source_system = src.source_system
        AND tgt.source_customer_id = src.source_customer_id
        WHEN MATCHED THEN UPDATE SET
            tgt.source_dedupe_group_id = src.source_dedupe_group_id,
            tgt.dedupe_key = src.dedupe_key,
            tgt.updated_at = src.updated_at
        WHEN NOT MATCHED THEN INSERT (
            source_system,
            source_customer_id,
            source_dedupe_group_id,
            dedupe_key,
            created_at,
            updated_at
        )
        VALUES (
            src.source_system,
            src.source_customer_id,
            src.source_dedupe_group_id,
            src.dedupe_key,
            CURRENT_TIMESTAMP(),
            src.updated_at
        )
    """)

def run_cross_source_matching(session: Session, batch_id: str):
    exec_sql(session, f"""
        CREATE OR REPLACE TEMP TABLE TMP_BATCH_KEYS AS
        SELECT
            c.source_system,
            c.source_customer_id,
            k.normalized_email,
            k.normalized_phone,
            k.loyalty_id,
            k.normalized_first_name,
            k.normalized_last_name,
            k.dob
        FROM IDENTITY.SOURCE_CUSTOMER c
        JOIN IDENTITY.SOURCE_CUSTOMER_KEYS k
          ON c.source_system = k.source_system
         AND c.source_customer_id = k.source_customer_id
        WHERE c.last_seen_batch_id = '{q(batch_id)}'
          AND c.active_flag = TRUE
    """)

    exec_sql(session, """
        CREATE OR REPLACE TEMP TABLE TMP_EXISTING_KEYS AS
        SELECT
            x.golden_customer_id,
            k.source_system,
            k.source_customer_id,
            k.normalized_email,
            k.normalized_phone,
            k.loyalty_id
        FROM IDENTITY.IDENTITY_CROSSWALK x
        JOIN IDENTITY.SOURCE_CUSTOMER_KEYS k
          ON x.source_system = k.source_system
         AND x.source_customer_id = k.source_customer_id
        WHERE x.active_flag = TRUE
    """)

    exec_sql(session, """
        CREATE OR REPLACE TEMP TABLE TMP_MATCHED AS
        SELECT
            b.source_system,
            b.source_customer_id,
            COALESCE(
                MAX(CASE WHEN b.loyalty_id IS NOT NULL AND b.loyalty_id = e.loyalty_id THEN e.golden_customer_id END),
                MAX(CASE WHEN b.normalized_email IS NOT NULL AND b.normalized_email = e.normalized_email THEN e.golden_customer_id END),
                MAX(CASE WHEN b.normalized_phone IS NOT NULL AND b.normalized_phone = e.normalized_phone THEN e.golden_customer_id END)
            ) AS matched_golden_customer_id,
            CASE
                WHEN MAX(CASE WHEN b.loyalty_id IS NOT NULL AND b.loyalty_id = e.loyalty_id THEN 1 ELSE 0 END) = 1 THEN 1.00
                WHEN MAX(CASE WHEN b.normalized_email IS NOT NULL AND b.normalized_email = e.normalized_email THEN 1 ELSE 0 END) = 1 THEN 0.95
                WHEN MAX(CASE WHEN b.normalized_phone IS NOT NULL AND b.normalized_phone = e.normalized_phone THEN 1 ELSE 0 END) = 1 THEN 0.90
                ELSE NULL
            END AS confidence
        FROM TMP_BATCH_KEYS b
        LEFT JOIN TMP_EXISTING_KEYS e
          ON (
              b.loyalty_id IS NOT NULL AND b.loyalty_id = e.loyalty_id
          )
          OR (
              b.normalized_email IS NOT NULL AND b.normalized_email = e.normalized_email
          )
          OR (
              b.normalized_phone IS NOT NULL AND b.normalized_phone = e.normalized_phone
          )
        GROUP BY b.source_system, b.source_customer_id
    """)

    exec_sql(session, """
        CREATE OR REPLACE TEMP TABLE TMP_RESOLVED AS
        SELECT
            b.source_system,
            b.source_customer_id,
            COALESCE(m.matched_golden_customer_id, UUID_STRING()) AS golden_customer_id,
            CASE WHEN m.matched_golden_customer_id IS NULL THEN 'NEW_GOLDEN' ELSE 'MATCHED_EXISTING' END AS resolution_type,
            COALESCE(m.confidence, 1.0) AS confidence
        FROM TMP_BATCH_KEYS b
        LEFT JOIN TMP_MATCHED m
          ON b.source_system = m.source_system
         AND b.source_customer_id = m.source_customer_id
    """)

    exec_sql(session, """
        MERGE INTO GOLD.GOLDEN_CUSTOMER tgt
        USING (
            SELECT
                r.golden_customer_id,
                c.first_name,
                c.last_name,
                c.email,
                c.phone,
                c.dob,
                c.address_line1,
                c.city,
                c.state,
                c.postal_code,
                c.country
            FROM TMP_RESOLVED r
            JOIN IDENTITY.SOURCE_CUSTOMER c
              ON r.source_system = c.source_system
             AND r.source_customer_id = c.source_customer_id
            WHERE r.resolution_type = 'NEW_GOLDEN'
        ) src
        ON tgt.golden_customer_id = src.golden_customer_id
        WHEN NOT MATCHED THEN INSERT (
            golden_customer_id,
            first_name,
            last_name,
            email,
            phone,
            dob,
            address_line1,
            city,
            state,
            postal_code,
            country,
            created_at,
            updated_at,
            active_flag
        )
        VALUES (
            src.golden_customer_id,
            src.first_name,
            src.last_name,
            src.email,
            src.phone,
            src.dob,
            src.address_line1,
            src.city,
            src.state,
            src.postal_code,
            src.country,
            CURRENT_TIMESTAMP(),
            CURRENT_TIMESTAMP(),
            TRUE
        )
    """)

    exec_sql(session, """
        MERGE INTO IDENTITY.IDENTITY_CROSSWALK tgt
        USING (
            SELECT
                golden_customer_id,
                source_system,
                source_customer_id,
                resolution_type,
                confidence
            FROM TMP_RESOLVED
        ) src
        ON  tgt.source_system = src.source_system
        AND tgt.source_customer_id = src.source_customer_id
        WHEN MATCHED THEN UPDATE SET
            tgt.golden_customer_id = src.golden_customer_id,
            tgt.match_type = src.resolution_type,
            tgt.match_confidence = src.confidence,
            tgt.updated_at = CURRENT_TIMESTAMP(),
            tgt.active_flag = TRUE
        WHEN NOT MATCHED THEN INSERT (
            golden_customer_id,
            source_system,
            source_customer_id,
            match_type,
            match_confidence,
            active_flag,
            created_at,
            updated_at
        )
        VALUES (
            src.golden_customer_id,
            src.source_system,
            src.source_customer_id,
            src.resolution_type,
            src.confidence,
            TRUE,
            CURRENT_TIMESTAMP(),
            CURRENT_TIMESTAMP()
        )
    """)

def refresh_golden_profile(session: Session):
    exec_sql(session, """
        CREATE OR REPLACE TABLE GOLD.GOLDEN_CUSTOMER_PROFILE AS
        SELECT
            g.golden_customer_id,
            g.first_name,
            g.last_name,
            g.email,
            g.phone,
            g.dob,
            g.city,
            g.state,
            g.country,
            ARRAY_AGG(DISTINCT x.source_system || ':' || x.source_customer_id) AS linked_source_keys,
            ARRAY_AGG(DISTINCT x.source_system) AS linked_source_systems,
            COUNT(DISTINCT x.source_system || ':' || x.source_customer_id) AS linked_source_record_count,
            CURRENT_TIMESTAMP() AS refreshed_at
        FROM GOLD.GOLDEN_CUSTOMER g
        LEFT JOIN IDENTITY.IDENTITY_CROSSWALK x
          ON g.golden_customer_id = x.golden_customer_id
         AND x.active_flag = TRUE
        WHERE g.active_flag = TRUE
        GROUP BY
            g.golden_customer_id,
            g.first_name,
            g.last_name,
            g.email,
            g.phone,
            g.dob,
            g.city,
            g.state,
            g.country
    """)

def mark_raw_complete(session: Session, batch_id: str, source_system: str):
    raw_table = CUSTOMER_RAW_TABLES.get(source_system.upper())
    if raw_table:
        exec_sql(session, f"""
            UPDATE {raw_table}
               SET process_status = 'COMPLETE',
                   processed_at = CURRENT_TIMESTAMP(),
                   error_message = NULL
             WHERE batch_id = '{q(batch_id)}'
               AND process_status IN ('NEW', 'LOADED', 'PROCESSING')
        """)

def process_one_batch(session: Session, batch: Dict) -> Dict:
    batch_id = batch["BATCH_ID"]
    source_system = batch["SOURCE_SYSTEM"].upper()

    mark_batch(session, batch_id, "PROCESSING")
    try:
        load_raw_customers_to_identity(session, batch_id, source_system)
        build_customer_keys(session, batch_id)
        run_within_source_dedupe(session, batch_id, source_system)
        run_cross_source_matching(session, batch_id)
        refresh_golden_profile(session)
        mark_raw_complete(session, batch_id, source_system)
        mark_batch(session, batch_id, "COMPLETE")

        return {
            "batch_id": batch_id,
            "source_system": source_system,
            "status": "COMPLETE",
        }
    except Exception as e:
        err = str(e)[:1500]
        mark_batch(session, batch_id, "ERROR", err)
        raw_table = CUSTOMER_RAW_TABLES.get(source_system)
        if raw_table:
            exec_sql(session, f"""
                UPDATE {raw_table}
                   SET process_status = 'ERROR',
                       error_message = '{q(err)}'
                 WHERE batch_id = '{q(batch_id)}'
                   AND COALESCE(process_status, 'NEW') <> 'COMPLETE'
            """)
        return {
            "batch_id": batch_id,
            "source_system": source_system,
            "status": "ERROR",
            "error": err,
        }

def main(session: Session, max_batches: int = 10):
    started_at = datetime.utcnow().isoformat()
    batches = get_pending_customer_batches(session, max_batches)
    results = [process_one_batch(session, batch) for batch in batches]

    return {
        "started_at_utc": started_at,
        "completed_at_utc": datetime.utcnow().isoformat(),
        "batches_found": len(batches),
        "results": results,
    }
$$;

-- Manual test:
-- CALL PROCESSING.PROCESS_PENDING_BATCHES(10);

-- Optional task:
-- CREATE OR REPLACE TASK PROCESSING.TASK_PROCESS_PENDING_BATCHES
--   WAREHOUSE = YOUR_WAREHOUSE_NAME
--   SCHEDULE = '1 MINUTE'
-- AS
--   CALL PROCESSING.PROCESS_PENDING_BATCHES(10);
--
-- ALTER TASK PROCESSING.TASK_PROCESS_PENDING_BATCHES RESUME;

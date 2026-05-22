-- Customer360 v2 - Rule-Driven Snowpark Python Stored Procedure
-- Procedure: PROCESSING.PROCESS_PENDING_BATCHES_RULE_DRIVEN
-- Reads matching weights and thresholds from CONFIG.RULE_CONDITION / CONFIG.RULE_SET.
-- Fix over prior deployment: all SQL subqueries explicitly project every column that
-- outer queries reference, preventing "invalid identifier 'SOURCE_SYSTEM'" errors.

USE DATABASE CUSTOMER360_V2;

CREATE OR REPLACE PROCEDURE PROCESSING.PROCESS_PENDING_BATCHES_RULE_DRIVEN(MAX_BATCHES INTEGER DEFAULT 10)
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
    "B4T":   "RAW.B4T_CUSTOMERS",
    "BRAZE": "RAW.BRAZE_PROFILES",
    "APP":   "RAW.APP_USERS",
}

def q(s) -> str:
    if s is None:
        return ""
    return str(s).replace("'", "''")

def exec_sql(session: Session, sql: str):
    return session.sql(sql).collect()

# ---------------------------------------------------------------------------
# Batch control helpers
# ---------------------------------------------------------------------------

def mark_batch(session: Session, batch_id: str, status: str, error: Optional[str] = None):
    if status == "PROCESSING":
        exec_sql(session, f"""
            UPDATE PROCESSING.BATCH_CONTROL
               SET status          = 'PROCESSING',
                   started_at      = COALESCE(started_at, CURRENT_TIMESTAMP()),
                   error_message   = NULL
             WHERE batch_id = '{q(batch_id)}'
        """)
    elif status == "COMPLETE":
        exec_sql(session, f"""
            UPDATE PROCESSING.BATCH_CONTROL
               SET status          = 'COMPLETE',
                   completed_at    = CURRENT_TIMESTAMP(),
                   error_message   = NULL
             WHERE batch_id = '{q(batch_id)}'
        """)
    elif status == "ERROR":
        exec_sql(session, f"""
            UPDATE PROCESSING.BATCH_CONTROL
               SET status          = 'ERROR',
                   completed_at    = CURRENT_TIMESTAMP(),
                   error_message   = '{q(error or "")}'
             WHERE batch_id = '{q(batch_id)}'
        """)

def get_pending_customer_batches(session: Session, max_batches: int) -> List[Dict]:
    # Explicitly alias every column so the result set is unambiguous.
    rows = exec_sql(session, f"""
        SELECT
            bc.batch_id       AS batch_id,
            bc.source_system  AS source_system,
            bc.entity_type    AS entity_type,
            bc.load_type      AS load_type,
            bc.file_name      AS file_name
        FROM PROCESSING.BATCH_CONTROL bc
        WHERE bc.status IN ('LOADED', 'NEW')
          AND UPPER(bc.entity_type) IN ('CUSTOMER', 'PROFILE')
        ORDER BY bc.created_at
        LIMIT {int(max_batches)}
    """)
    return [r.as_dict() for r in rows]

# ---------------------------------------------------------------------------
# Rule loading
# ---------------------------------------------------------------------------

def load_active_rules(session: Session) -> Dict:
    """Return the active rule set header and its conditions."""
    rule_rows = exec_sql(session, """
        SELECT
            rs.rule_version_id       AS rule_version_id,
            rs.auto_match_threshold  AS auto_match_threshold,
            rs.review_threshold      AS review_threshold
        FROM CONFIG.RULE_SET rs
        WHERE rs.status = 'ACTIVE'
        ORDER BY rs.created_at DESC
        LIMIT 1
    """)
    if not rule_rows:
        return {
            "rule_version_id": "RULE_V1",
            "auto_match_threshold": 0.90,
            "review_threshold": 0.75,
            "conditions": [],
        }
    rule = rule_rows[0].as_dict()

    cond_rows = exec_sql(session, f"""
        SELECT
            rc.rule_name        AS rule_name,
            rc.field_name       AS field_name,
            rc.match_type       AS match_type,
            rc.weight           AS weight,
            rc.condition_order  AS condition_order
        FROM CONFIG.RULE_CONDITION rc
        WHERE rc.rule_version_id = '{q(rule["RULE_VERSION_ID"])}'
          AND rc.enabled = TRUE
        ORDER BY rc.condition_order
    """)
    rule["conditions"] = [r.as_dict() for r in cond_rows]
    return rule

# ---------------------------------------------------------------------------
# Stage 1 – raw → IDENTITY.SOURCE_CUSTOMER
# ---------------------------------------------------------------------------

def load_raw_customers_to_identity(session: Session, batch_id: str, source_system: str):
    raw_table = CUSTOMER_RAW_TABLES.get(source_system)
    if not raw_table:
        raise ValueError(f"No raw customer table for source_system={source_system}")

    exec_sql(session, f"""
        MERGE INTO IDENTITY.SOURCE_CUSTOMER tgt
        USING (
            SELECT
                r.source_system     AS source_system,
                r.source_customer_id AS source_customer_id,
                r.first_name,
                r.last_name,
                r.email,
                r.phone,
                r.dob,
                r.address_line1,
                r.city,
                r.state,
                r.postal_code,
                r.country,
                r.loyalty_id,
                r.batch_id          AS batch_id,
                r.raw_record_id     AS raw_record_id
            FROM {raw_table} r
            WHERE r.batch_id = '{q(batch_id)}'
              AND COALESCE(r.process_status, 'NEW') IN ('NEW', 'LOADED')
        ) src
        ON  tgt.source_system      = src.source_system
        AND tgt.source_customer_id = src.source_customer_id
        WHEN MATCHED THEN UPDATE SET
            tgt.first_name         = src.first_name,
            tgt.last_name          = src.last_name,
            tgt.email              = src.email,
            tgt.phone              = src.phone,
            tgt.dob                = src.dob,
            tgt.address_line1      = src.address_line1,
            tgt.city               = src.city,
            tgt.state              = src.state,
            tgt.postal_code        = src.postal_code,
            tgt.country            = src.country,
            tgt.loyalty_id         = src.loyalty_id,
            tgt.batch_id           = src.batch_id,
            tgt.updated_at         = CURRENT_TIMESTAMP()
        WHEN NOT MATCHED THEN INSERT (
            source_record_uid,
            source_system,
            source_customer_id,
            batch_id,
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
            raw_record_id,
            created_at,
            updated_at,
            active_flag
        )
        VALUES (
            UUID_STRING(),
            src.source_system,
            src.source_customer_id,
            src.batch_id,
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

# ---------------------------------------------------------------------------
# Stage 2 – build normalised keys
# ---------------------------------------------------------------------------

def build_customer_keys(session: Session, batch_id: str):
    exec_sql(session, f"""
        MERGE INTO IDENTITY.SOURCE_CUSTOMER_KEYS tgt
        USING (
            SELECT
                c.source_system                                       AS source_system,
                c.source_customer_id                                  AS source_customer_id,
                c.source_record_uid                                   AS source_record_uid,
                LOWER(TRIM(c.email))                                  AS normalized_email,
                CASE WHEN c.phone IS NULL THEN NULL
                     ELSE REGEXP_REPLACE(c.phone, '[^0-9]', '')
                END                                                   AS normalized_phone,
                LOWER(REGEXP_REPLACE(TRIM(COALESCE(c.first_name,'')), '[^A-Za-z ]', ''))
                                                                      AS normalized_first_name,
                LOWER(REGEXP_REPLACE(TRIM(COALESCE(c.last_name,'')),  '[^A-Za-z ]', ''))
                                                                      AS normalized_last_name,
                LOWER(REGEXP_REPLACE(
                        TRIM(COALESCE(c.first_name,'') || ' ' || COALESCE(c.last_name,'')),
                        '[^A-Za-z ]', ''))                            AS normalized_full_name,
                c.dob                                                 AS dob,
                LOWER(TRIM(c.postal_code))                            AS postal_code,
                NULLIF(TRIM(c.loyalty_id), '')                        AS loyalty_id,
                SPLIT_PART(LOWER(TRIM(c.email)), '@', 2)              AS blocking_email_domain,
                RIGHT(REGEXP_REPLACE(COALESCE(c.phone,''), '[^0-9]', ''), 4)
                                                                      AS blocking_phone_last4,
                LOWER(REGEXP_REPLACE(
                        TRIM(COALESCE(c.first_name,'') || COALESCE(c.last_name,'')),
                        '[^A-Za-z]', ''))
                    || ':' || COALESCE(TO_VARCHAR(c.dob), '')         AS blocking_name_dob,
                CURRENT_TIMESTAMP()                                   AS updated_at
            FROM IDENTITY.SOURCE_CUSTOMER c
            WHERE c.batch_id   = '{q(batch_id)}'
              AND c.active_flag = TRUE
        ) src
        ON  tgt.source_system      = src.source_system
        AND tgt.source_customer_id = src.source_customer_id
        WHEN MATCHED THEN UPDATE SET
            tgt.source_record_uid     = src.source_record_uid,
            tgt.normalized_email      = src.normalized_email,
            tgt.normalized_phone      = src.normalized_phone,
            tgt.normalized_first_name = src.normalized_first_name,
            tgt.normalized_last_name  = src.normalized_last_name,
            tgt.normalized_full_name  = src.normalized_full_name,
            tgt.dob                   = src.dob,
            tgt.postal_code           = src.postal_code,
            tgt.loyalty_id            = src.loyalty_id,
            tgt.blocking_email_domain = src.blocking_email_domain,
            tgt.blocking_phone_last4  = src.blocking_phone_last4,
            tgt.blocking_name_dob     = src.blocking_name_dob
        WHEN NOT MATCHED THEN INSERT (
            source_system,
            source_customer_id,
            source_record_uid,
            normalized_email,
            normalized_phone,
            normalized_first_name,
            normalized_last_name,
            normalized_full_name,
            dob,
            postal_code,
            loyalty_id,
            blocking_email_domain,
            blocking_phone_last4,
            blocking_name_dob,
            created_at
        )
        VALUES (
            src.source_system,
            src.source_customer_id,
            src.source_record_uid,
            src.normalized_email,
            src.normalized_phone,
            src.normalized_first_name,
            src.normalized_last_name,
            src.normalized_full_name,
            src.dob,
            src.postal_code,
            src.loyalty_id,
            src.blocking_email_domain,
            src.blocking_phone_last4,
            src.blocking_name_dob,
            CURRENT_TIMESTAMP()
        )
    """)

# ---------------------------------------------------------------------------
# Stage 3 – within-source dedupe
# ---------------------------------------------------------------------------

def run_within_source_dedupe(session: Session, batch_id: str, source_system: str):
    exec_sql(session, f"""
        CREATE OR REPLACE TEMP TABLE TMP_DEDUPE_INPUT AS
        SELECT
            k.source_system        AS source_system,
            k.source_customer_id   AS source_customer_id,
            k.source_record_uid    AS source_record_uid,
            COALESCE(
                'LOYALTY:'  || NULLIF(k.loyalty_id, ''),
                'EMAIL:'    || NULLIF(k.normalized_email, ''),
                'PHONE:'    || NULLIF(k.normalized_phone, ''),
                'SRC:'      || k.source_system || ':' || k.source_customer_id
            )                      AS dedupe_key
        FROM IDENTITY.SOURCE_CUSTOMER_KEYS k
        JOIN IDENTITY.SOURCE_CUSTOMER c
          ON  c.source_system      = k.source_system
          AND c.source_customer_id = k.source_customer_id
        WHERE c.batch_id      = '{q(batch_id)}'
          AND k.source_system = '{q(source_system)}'
    """)

    exec_sql(session, """
        CREATE OR REPLACE TEMP TABLE TMP_DEDUPE_GROUPS AS
        SELECT
            d.source_system                AS source_system,
            d.dedupe_key                   AS dedupe_key,
            MIN(d.source_customer_id)      AS source_dedupe_group_id
        FROM TMP_DEDUPE_INPUT d
        GROUP BY d.source_system, d.dedupe_key
    """)

    exec_sql(session, """
        MERGE INTO IDENTITY.SOURCE_DEDUPE_MEMBER tgt
        USING (
            SELECT
                di.source_system        AS source_system,
                di.source_customer_id   AS source_customer_id,
                di.source_record_uid    AS source_record_uid,
                dg.source_dedupe_group_id AS source_dedupe_group_id,
                di.dedupe_key           AS dedupe_key,
                CURRENT_TIMESTAMP()     AS updated_at
            FROM TMP_DEDUPE_INPUT di
            JOIN TMP_DEDUPE_GROUPS dg
              ON  di.source_system = dg.source_system
              AND di.dedupe_key    = dg.dedupe_key
        ) src
        ON  tgt.source_system      = src.source_system
        AND tgt.source_customer_id = src.source_customer_id
        WHEN MATCHED THEN UPDATE SET
            tgt.source_record_uid      = src.source_record_uid,
            tgt.dedupe_group_id        = src.source_dedupe_group_id,
            tgt.rule_name              = src.dedupe_key
        WHEN NOT MATCHED THEN INSERT (
            source_system,
            source_customer_id,
            source_record_uid,
            dedupe_group_id,
            rule_name
        )
        VALUES (
            src.source_system,
            src.source_customer_id,
            src.source_record_uid,
            src.source_dedupe_group_id,
            src.dedupe_key
        )
    """)

# ---------------------------------------------------------------------------
# Stage 4 – rule-driven cross-source matching
# ---------------------------------------------------------------------------

def run_rule_driven_cross_source_matching(session: Session, batch_id: str, rules: Dict):
    rule_version_id  = rules.get("RULE_VERSION_ID", rules.get("rule_version_id", "RULE_V1"))
    auto_threshold   = float(rules.get("AUTO_MATCH_THRESHOLD", rules.get("auto_match_threshold", 0.90)))
    review_threshold = float(rules.get("REVIEW_THRESHOLD", rules.get("review_threshold", 0.75)))
    conditions       = rules.get("conditions", [])

    # Build CASE WHEN scoring expression from rule conditions.
    score_fragments = []
    for cond in conditions:
        field    = str(cond.get("FIELD_NAME", cond.get("field_name", ""))).lower()
        weight   = float(cond.get("WEIGHT", cond.get("weight", 0.0)))
        if field == "loyalty_id":
            score_fragments.append(
                f"CASE WHEN b.loyalty_id IS NOT NULL AND b.loyalty_id = e.loyalty_id THEN {weight} ELSE 0 END"
            )
        elif field == "normalized_email":
            score_fragments.append(
                f"CASE WHEN b.normalized_email IS NOT NULL AND b.normalized_email = e.normalized_email THEN {weight} ELSE 0 END"
            )
        elif field == "normalized_phone":
            score_fragments.append(
                f"CASE WHEN b.normalized_phone IS NOT NULL AND b.normalized_phone = e.normalized_phone THEN {weight} ELSE 0 END"
            )
        elif "name" in field and "dob" in field:
            score_fragments.append(
                f"CASE WHEN b.normalized_full_name IS NOT NULL AND b.normalized_full_name = e.normalized_full_name AND b.dob IS NOT NULL AND b.dob = e.dob THEN {weight} ELSE 0 END"
            )

    if not score_fragments:
        # Fallback: loyalty > email > phone
        score_expr = """
            CASE WHEN b.loyalty_id IS NOT NULL AND b.loyalty_id = e.loyalty_id THEN 0.35 ELSE 0 END
          + CASE WHEN b.normalized_email IS NOT NULL AND b.normalized_email = e.normalized_email THEN 0.30 ELSE 0 END
          + CASE WHEN b.normalized_phone IS NOT NULL AND b.normalized_phone = e.normalized_phone THEN 0.25 ELSE 0 END
        """
    else:
        score_expr = "\n          + ".join(score_fragments)

    exec_sql(session, f"""
        CREATE OR REPLACE TEMP TABLE TMP_BATCH_KEYS AS
        SELECT
            c.source_system        AS source_system,
            c.source_customer_id   AS source_customer_id,
            k.normalized_email     AS normalized_email,
            k.normalized_phone     AS normalized_phone,
            k.normalized_full_name AS normalized_full_name,
            k.loyalty_id           AS loyalty_id,
            k.dob                  AS dob
        FROM IDENTITY.SOURCE_CUSTOMER c
        JOIN IDENTITY.SOURCE_CUSTOMER_KEYS k
          ON  k.source_system      = c.source_system
          AND k.source_customer_id = c.source_customer_id
        WHERE c.batch_id    = '{q(batch_id)}'
          AND c.active_flag = TRUE
    """)

    exec_sql(session, """
        CREATE OR REPLACE TEMP TABLE TMP_EXISTING_KEYS AS
        SELECT
            x.golden_customer_id   AS golden_customer_id,
            k.source_system        AS source_system,
            k.source_customer_id   AS source_customer_id,
            k.normalized_email     AS normalized_email,
            k.normalized_phone     AS normalized_phone,
            k.normalized_full_name AS normalized_full_name,
            k.loyalty_id           AS loyalty_id,
            k.dob                  AS dob
        FROM IDENTITY.IDENTITY_CROSSWALK x
        JOIN IDENTITY.SOURCE_CUSTOMER_KEYS k
          ON  k.source_system      = x.source_system
          AND k.source_customer_id = x.source_customer_id
        WHERE x.active_flag = TRUE
    """)

    exec_sql(session, f"""
        CREATE OR REPLACE TEMP TABLE TMP_CANDIDATE_SCORES AS
        SELECT
            b.source_system                AS source_system,
            b.source_customer_id           AS source_customer_id,
            e.golden_customer_id           AS candidate_golden_id,
            (
              {score_expr}
            )                              AS score
        FROM TMP_BATCH_KEYS b
        JOIN TMP_EXISTING_KEYS e
          ON (
                (b.loyalty_id IS NOT NULL AND b.loyalty_id = e.loyalty_id)
             OR (b.normalized_email IS NOT NULL AND b.normalized_email = e.normalized_email)
             OR (b.normalized_phone IS NOT NULL AND b.normalized_phone = e.normalized_phone)
             OR (b.normalized_full_name IS NOT NULL AND b.normalized_full_name = e.normalized_full_name AND b.dob IS NOT NULL AND b.dob = e.dob)
          )
    """)

    exec_sql(session, f"""
        CREATE OR REPLACE TEMP TABLE TMP_BEST_MATCH AS
        SELECT
            cs.source_system        AS source_system,
            cs.source_customer_id   AS source_customer_id,
            cs.candidate_golden_id  AS candidate_golden_id,
            cs.score                AS score
        FROM (
            SELECT
                source_system,
                source_customer_id,
                candidate_golden_id,
                score,
                ROW_NUMBER() OVER (
                    PARTITION BY source_system, source_customer_id
                    ORDER BY score DESC
                ) AS rn
            FROM TMP_CANDIDATE_SCORES
            WHERE score >= {review_threshold}
        ) cs
        WHERE cs.rn = 1
    """)

    # Queue uncertain matches (review_threshold <= score < auto_threshold) for stewardship.
    exec_sql(session, f"""
        INSERT INTO IDENTITY.STEWARDSHIP_QUEUE (
            match_run_id,
            left_source_system,
            left_source_customer_id,
            right_source_system,
            right_source_customer_id,
            score,
            reason,
            status
        )
        SELECT
            '{q(batch_id)}'              AS match_run_id,
            bm.source_system             AS left_source_system,
            bm.source_customer_id        AS left_source_customer_id,
            ek.source_system             AS right_source_system,
            ek.source_customer_id        AS right_source_customer_id,
            bm.score                     AS score,
            'Rule-driven: score between review and auto threshold' AS reason,
            'OPEN'                       AS status
        FROM TMP_BEST_MATCH bm
        JOIN TMP_EXISTING_KEYS ek
          ON ek.golden_customer_id = bm.candidate_golden_id
        WHERE bm.score >= {review_threshold}
          AND bm.score <  {auto_threshold}
    """)

    exec_sql(session, f"""
        CREATE OR REPLACE TEMP TABLE TMP_RESOLVED AS
        SELECT
            b.source_system                                                AS source_system,
            b.source_customer_id                                           AS source_customer_id,
            COALESCE(bm.candidate_golden_id, UUID_STRING())               AS golden_customer_id,
            CASE
                WHEN bm.candidate_golden_id IS NULL         THEN 'NEW_GOLDEN'
                WHEN bm.score >= {auto_threshold}            THEN 'MATCHED_EXISTING'
                ELSE 'REVIEW_PENDING'
            END                                                            AS resolution_type,
            COALESCE(bm.score, 1.0)                                        AS confidence,
            '{q(rule_version_id)}'                                         AS rule_version_id
        FROM TMP_BATCH_KEYS b
        LEFT JOIN TMP_BEST_MATCH bm
          ON  bm.source_system      = b.source_system
          AND bm.source_customer_id = b.source_customer_id
          AND bm.score >= {auto_threshold}
    """)

    # Insert new golden records.
    exec_sql(session, f"""
        MERGE INTO GOLD.GOLDEN_CUSTOMER tgt
        USING (
            SELECT
                r.golden_customer_id   AS golden_customer_id,
                r.rule_version_id      AS rule_version_id,
                c.first_name,
                c.last_name,
                c.email,
                c.phone,
                c.dob,
                c.address_line1,
                c.city,
                c.state,
                c.postal_code,
                c.country,
                c.loyalty_id
            FROM TMP_RESOLVED r
            JOIN IDENTITY.SOURCE_CUSTOMER c
              ON  c.source_system      = r.source_system
              AND c.source_customer_id = r.source_customer_id
            WHERE r.resolution_type = 'NEW_GOLDEN'
        ) src
        ON tgt.golden_customer_id = src.golden_customer_id
        WHEN NOT MATCHED THEN INSERT (
            golden_customer_id,
            rule_version_id,
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
            created_at,
            updated_at,
            status
        )
        VALUES (
            src.golden_customer_id,
            src.rule_version_id,
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
            CURRENT_TIMESTAMP(),
            CURRENT_TIMESTAMP(),
            'ACTIVE'
        )
    """)

    # Update crosswalk.
    exec_sql(session, f"""
        MERGE INTO IDENTITY.IDENTITY_CROSSWALK tgt
        USING (
            SELECT
                r.golden_customer_id   AS golden_customer_id,
                r.source_system        AS source_system,
                r.source_customer_id   AS source_customer_id,
                r.resolution_type      AS link_type,
                r.confidence           AS confidence,
                r.rule_version_id      AS rule_version_id
            FROM TMP_RESOLVED r
            WHERE r.resolution_type IN ('NEW_GOLDEN', 'MATCHED_EXISTING')
        ) src
        ON  tgt.source_system      = src.source_system
        AND tgt.source_customer_id = src.source_customer_id
        WHEN MATCHED THEN UPDATE SET
            tgt.golden_customer_id = src.golden_customer_id,
            tgt.link_type          = src.link_type,
            tgt.confidence         = src.confidence,
            tgt.rule_version_id    = src.rule_version_id,
            tgt.updated_at         = CURRENT_TIMESTAMP(),
            tgt.active_flag        = TRUE
        WHEN NOT MATCHED THEN INSERT (
            golden_customer_id,
            source_system,
            source_customer_id,
            link_type,
            confidence,
            rule_version_id,
            active_flag,
            linked_at,
            updated_at
        )
        VALUES (
            src.golden_customer_id,
            src.source_system,
            src.source_customer_id,
            src.link_type,
            src.confidence,
            src.rule_version_id,
            TRUE,
            CURRENT_TIMESTAMP(),
            CURRENT_TIMESTAMP()
        )
    """)

# ---------------------------------------------------------------------------
# Stage 5 – refresh golden profile
# ---------------------------------------------------------------------------

def refresh_golden_profile(session: Session):
    exec_sql(session, """
        CALL GOLD.REFRESH_GOLDEN_CUSTOMER_PROFILE()
    """)

# ---------------------------------------------------------------------------
# Stage 6 – mark raw records complete
# ---------------------------------------------------------------------------

def mark_raw_complete(session: Session, batch_id: str, source_system: str):
    raw_table = CUSTOMER_RAW_TABLES.get(source_system)
    if raw_table:
        exec_sql(session, f"""
            UPDATE {raw_table}
               SET process_status = 'COMPLETE',
                   processed_at   = CURRENT_TIMESTAMP(),
                   error_message  = NULL
             WHERE batch_id       = '{q(batch_id)}'
               AND process_status IN ('NEW', 'LOADED', 'PROCESSING')
        """)

# ---------------------------------------------------------------------------
# Per-batch orchestration
# ---------------------------------------------------------------------------

def process_one_batch(session: Session, batch: Dict, rules: Dict) -> Dict:
    batch_id      = batch["BATCH_ID"]
    source_system = batch["SOURCE_SYSTEM"].upper()

    mark_batch(session, batch_id, "PROCESSING")
    try:
        load_raw_customers_to_identity(session, batch_id, source_system)
        build_customer_keys(session, batch_id)
        run_within_source_dedupe(session, batch_id, source_system)
        run_rule_driven_cross_source_matching(session, batch_id, rules)
        refresh_golden_profile(session)
        mark_raw_complete(session, batch_id, source_system)
        mark_batch(session, batch_id, "COMPLETE")
        return {"batch_id": batch_id, "source_system": source_system, "status": "COMPLETE"}

    except Exception as e:
        err = str(e)[:1500]
        mark_batch(session, batch_id, "ERROR", err)
        raw_table = CUSTOMER_RAW_TABLES.get(source_system)
        if raw_table:
            exec_sql(session, f"""
                UPDATE {raw_table}
                   SET process_status = 'ERROR',
                       error_message  = '{q(err)}'
                 WHERE batch_id       = '{q(batch_id)}'
                   AND COALESCE(process_status, 'NEW') <> 'COMPLETE'
            """)
        return {"batch_id": batch_id, "source_system": source_system, "status": "ERROR", "error": err}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main(session: Session, max_batches: int = 10):
    started_at = datetime.utcnow().isoformat()
    rules      = load_active_rules(session)
    batches    = get_pending_customer_batches(session, max_batches)
    results    = [process_one_batch(session, b, rules) for b in batches]

    return {
        "started_at_utc":   started_at,
        "completed_at_utc": datetime.utcnow().isoformat(),
        "rule_version_id":  rules.get("RULE_VERSION_ID", rules.get("rule_version_id")),
        "batches_found":    len(batches),
        "results":          results,
    }
$$;

-- Deploy and test:
-- CALL PROCESSING.PROCESS_PENDING_BATCHES_RULE_DRIVEN(10);

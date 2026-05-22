CREATE OR REPLACE PROCEDURE PROCESSING.PROCESS_PENDING_BATCHES_RULE_DRIVEN(MAX_BATCHES INTEGER DEFAULT 10)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'main'
EXECUTE AS OWNER
AS
$$
from datetime import datetime
from snowflake.snowpark import Session

CUSTOMER_RAW_TABLES = {
    "OPERA": "RAW.OPERA_CUSTOMERS",
    "B4T": "RAW.B4T_CUSTOMERS",
    "BRAZE": "RAW.BRAZE_PROFILES",
    "APP": "RAW.APP_USERS",
}

DEFAULT_AUTO_THRESHOLD = 0.92
DEFAULT_REVIEW_THRESHOLD = 0.78

DEFAULT_WEIGHTS = {
    "LOYALTY_EXACT": 0.35,
    "EMAIL_EXACT": 0.25,
    "PHONE_EXACT": 0.20,
    "DOB_EXACT": 0.08,
    "ZIP_EXACT": 0.04,
    "NAME_FUZZY": 0.08
}

def q(v):
    return "" if v is None else str(v).replace("'", "''")

def exec_sql(session, sql):
    return session.sql(sql).collect()

def ensure_objects(session):
    exec_sql(session, """
        CREATE TABLE IF NOT EXISTS IDENTITY.IDENTITY_EVENT_LOG (
            EVENT_ID STRING DEFAULT UUID_STRING(),
            EVENT_TS TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
            EVENT_TYPE STRING,
            GOLDEN_CUSTOMER_ID STRING,
            SOURCE_SYSTEM STRING,
            SOURCE_CUSTOMER_ID STRING,
            CANDIDATE_GOLDEN_CUSTOMER_ID STRING,
            CANDIDATE_SOURCE_SYSTEM STRING,
            CANDIDATE_SOURCE_CUSTOMER_ID STRING,
            MATCH_SCORE FLOAT,
            MATCH_REASON STRING,
            RULE_SET_ID STRING,
            RULE_VERSION INTEGER,
            OPERATOR STRING,
            REASON STRING,
            PAYLOAD VARIANT
        )
    """)

    exec_sql(session, """
        CREATE TABLE IF NOT EXISTS IDENTITY.MATCH_REJECTION_REGISTRY (
            REJECTION_ID STRING DEFAULT UUID_STRING(),
            SOURCE_SYSTEM STRING,
            SOURCE_CUSTOMER_ID STRING,
            REJECTED_GOLDEN_CUSTOMER_ID STRING,
            REJECTED_SOURCE_SYSTEM STRING,
            REJECTED_SOURCE_CUSTOMER_ID STRING,
            REASON STRING,
            REJECTED_BY STRING,
            REJECTED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
            ACTIVE_FLAG BOOLEAN DEFAULT TRUE
        )
    """)

def get_rule_config(session):
    try:
        rows = session.sql("""
            SELECT RULE_SET_ID,
                   COALESCE(RULE_VERSION,1) RULE_VERSION,
                   COALESCE(AUTO_MATCH_THRESHOLD,0.92) AUTO_MATCH_THRESHOLD,
                   COALESCE(REVIEW_THRESHOLD,0.78) REVIEW_THRESHOLD
            FROM CONFIG.RULE_SET
            WHERE COALESCE(ACTIVE_FLAG,TRUE)=TRUE
              AND UPPER(RULE_TYPE) IN ('MATCH','CROSS_SOURCE_MATCH')
            ORDER BY COALESCE(RULE_VERSION,1) DESC
            LIMIT 1
        """).collect()
    except Exception:
        rows = []

    if not rows:
        return {
            "rule_set_id": "DEFAULT",
            "rule_version": 1,
            "auto_threshold": DEFAULT_AUTO_THRESHOLD,
            "review_threshold": DEFAULT_REVIEW_THRESHOLD,
            "weights": DEFAULT_WEIGHTS
        }

    r = rows[0].as_dict()
    weights = DEFAULT_WEIGHTS.copy()

    try:
        conds = session.sql(f"""
            SELECT UPPER(COALESCE(CONDITION_NAME,'')) CONDITION_NAME,
                   UPPER(COALESCE(FIELD_NAME,'')) FIELD_NAME,
                   COALESCE(WEIGHT,0) WEIGHT
            FROM CONFIG.RULE_CONDITION
            WHERE RULE_SET_ID = '{q(r["RULE_SET_ID"])}'
              AND COALESCE(ACTIVE_FLAG,TRUE)=TRUE
        """).collect()

        for c in conds:
            d = c.as_dict()
            name = d["CONDITION_NAME"]
            field = d["FIELD_NAME"]
            weight = float(d["WEIGHT"] or 0)

            if weight <= 0:
                continue

            if "LOYALTY" in name or field == "LOYALTY_ID":
                weights["LOYALTY_EXACT"] = weight
            elif "EMAIL" in name or field == "EMAIL":
                weights["EMAIL_EXACT"] = weight
            elif "PHONE" in name or field == "PHONE":
                weights["PHONE_EXACT"] = weight
            elif "DOB" in name or field == "DOB":
                weights["DOB_EXACT"] = weight
            elif "ZIP" in name or "POSTAL" in name or field in ("ZIP","POSTAL_CODE"):
                weights["ZIP_EXACT"] = weight
            elif "NAME" in name or field in ("NAME","FULL_NAME","FIRST_NAME","LAST_NAME"):
                weights["NAME_FUZZY"] = weight

        total = sum(weights.values())
        if total > 2:
            weights = {k: v / total for k, v in weights.items()}

    except Exception:
        pass

    return {
        "rule_set_id": r["RULE_SET_ID"],
        "rule_version": int(r["RULE_VERSION"]),
        "auto_threshold": float(r["AUTO_MATCH_THRESHOLD"]),
        "review_threshold": float(r["REVIEW_THRESHOLD"]),
        "weights": weights
    }

def get_batches(session, max_batches):
    rows = exec_sql(session, f"""
        SELECT BATCH_ID, SOURCE_SYSTEM, ENTITY_TYPE
        FROM PROCESSING.BATCH_CONTROL
        WHERE STATUS IN ('LOADED','NEW')
          AND UPPER(ENTITY_TYPE) IN ('CUSTOMER','PROFILE')
        ORDER BY CREATED_AT
        LIMIT {int(max_batches)}
    """)
    return [r.as_dict() for r in rows]

def mark_batch(session, batch_id, status, error=None):
    if status == "PROCESSING":
        exec_sql(session, f"""
            UPDATE PROCESSING.BATCH_CONTROL
            SET STATUS='PROCESSING',
                STARTED_AT=COALESCE(STARTED_AT,CURRENT_TIMESTAMP()),
                ERROR_MESSAGE=NULL
            WHERE BATCH_ID='{q(batch_id)}'
        """)
    elif status == "COMPLETE":
        exec_sql(session, f"""
            UPDATE PROCESSING.BATCH_CONTROL
            SET STATUS='COMPLETE',
                COMPLETED_AT=CURRENT_TIMESTAMP(),
                ERROR_MESSAGE=NULL
            WHERE BATCH_ID='{q(batch_id)}'
        """)
    else:
        exec_sql(session, f"""
            UPDATE PROCESSING.BATCH_CONTROL
            SET STATUS='ERROR',
                COMPLETED_AT=CURRENT_TIMESTAMP(),
                ERROR_MESSAGE='{q(error)}'
            WHERE BATCH_ID='{q(batch_id)}'
        """)

def process_batch(session, batch, cfg):
    batch_id = batch["BATCH_ID"]
    source_system = batch["SOURCE_SYSTEM"].upper()
    raw_table = CUSTOMER_RAW_TABLES[source_system]
    w = cfg["weights"]

    mark_batch(session, batch_id, "PROCESSING")

    exec_sql(session, f"""
        MERGE INTO IDENTITY.SOURCE_CUSTOMER tgt
        USING (
            SELECT SOURCE_SYSTEM, SOURCE_CUSTOMER_ID, FIRST_NAME, LAST_NAME, EMAIL, PHONE,
                   DOB, ADDRESS_LINE1, CITY, STATE, POSTAL_CODE, COUNTRY, LOYALTY_ID,
                   BATCH_ID, RAW_RECORD_ID
            FROM {raw_table}
            WHERE BATCH_ID='{q(batch_id)}'
              AND COALESCE(PROCESS_STATUS,'NEW') IN ('NEW','LOADED')
        ) src
        ON tgt.SOURCE_SYSTEM=src.SOURCE_SYSTEM
       AND tgt.SOURCE_CUSTOMER_ID=src.SOURCE_CUSTOMER_ID
        WHEN MATCHED THEN UPDATE SET
            FIRST_NAME=src.FIRST_NAME,
            LAST_NAME=src.LAST_NAME,
            EMAIL=src.EMAIL,
            PHONE=src.PHONE,
            DOB=src.DOB,
            ADDRESS_LINE1=src.ADDRESS_LINE1,
            CITY=src.CITY,
            STATE=src.STATE,
            POSTAL_CODE=src.POSTAL_CODE,
            COUNTRY=src.COUNTRY,
            LOYALTY_ID=src.LOYALTY_ID,
            LAST_SEEN_BATCH_ID=src.BATCH_ID,
            UPDATED_AT=CURRENT_TIMESTAMP()
        WHEN NOT MATCHED THEN INSERT (
            SOURCE_CUSTOMER_UID, SOURCE_SYSTEM, SOURCE_CUSTOMER_ID,
            FIRST_NAME, LAST_NAME, EMAIL, PHONE, DOB,
            ADDRESS_LINE1, CITY, STATE, POSTAL_CODE, COUNTRY, LOYALTY_ID,
            FIRST_SEEN_BATCH_ID, LAST_SEEN_BATCH_ID, RAW_RECORD_ID,
            CREATED_AT, UPDATED_AT, ACTIVE_FLAG
        )
        VALUES (
            UUID_STRING(), src.SOURCE_SYSTEM, src.SOURCE_CUSTOMER_ID,
            src.FIRST_NAME, src.LAST_NAME, src.EMAIL, src.PHONE, src.DOB,
            src.ADDRESS_LINE1, src.CITY, src.STATE, src.POSTAL_CODE, src.COUNTRY, src.LOYALTY_ID,
            src.BATCH_ID, src.BATCH_ID, src.RAW_RECORD_ID,
            CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP(), TRUE
        )
    """)

    exec_sql(session, f"""
        MERGE INTO IDENTITY.SOURCE_CUSTOMER_KEYS tgt
        USING (
            SELECT SOURCE_SYSTEM,
                   SOURCE_CUSTOMER_ID,
                   LOWER(TRIM(EMAIL)) NORMALIZED_EMAIL,
                   REGEXP_REPLACE(PHONE,'[^0-9]','') NORMALIZED_PHONE,
                   LOWER(TRIM(FIRST_NAME)) NORMALIZED_FIRST_NAME,
                   LOWER(TRIM(LAST_NAME)) NORMALIZED_LAST_NAME,
                   LOWER(TRIM(COALESCE(FIRST_NAME,'') || ' ' || COALESCE(LAST_NAME,''))) NORMALIZED_FULL_NAME,
                   DOB,
                   LOWER(TRIM(POSTAL_CODE)) NORMALIZED_POSTAL_CODE,
                   LOWER(TRIM(CITY)) NORMALIZED_CITY,
                   NULLIF(TRIM(LOYALTY_ID),'') LOYALTY_ID
            FROM IDENTITY.SOURCE_CUSTOMER
            WHERE LAST_SEEN_BATCH_ID='{q(batch_id)}'
              AND ACTIVE_FLAG=TRUE
        ) src
        ON tgt.SOURCE_SYSTEM=src.SOURCE_SYSTEM
       AND tgt.SOURCE_CUSTOMER_ID=src.SOURCE_CUSTOMER_ID
        WHEN MATCHED THEN UPDATE SET
            NORMALIZED_EMAIL=src.NORMALIZED_EMAIL,
            NORMALIZED_PHONE=src.NORMALIZED_PHONE,
            NORMALIZED_FIRST_NAME=src.NORMALIZED_FIRST_NAME,
            NORMALIZED_LAST_NAME=src.NORMALIZED_LAST_NAME,
            NORMALIZED_FULL_NAME=src.NORMALIZED_FULL_NAME,
            DOB=src.DOB,
            NORMALIZED_POSTAL_CODE=src.NORMALIZED_POSTAL_CODE,
            NORMALIZED_CITY=src.NORMALIZED_CITY,
            LOYALTY_ID=src.LOYALTY_ID,
            UPDATED_AT=CURRENT_TIMESTAMP()
        WHEN NOT MATCHED THEN INSERT (
            SOURCE_SYSTEM, SOURCE_CUSTOMER_ID, NORMALIZED_EMAIL, NORMALIZED_PHONE,
            NORMALIZED_FIRST_NAME, NORMALIZED_LAST_NAME, NORMALIZED_FULL_NAME,
            DOB, NORMALIZED_POSTAL_CODE, NORMALIZED_CITY, LOYALTY_ID, UPDATED_AT
        )
        VALUES (
            src.SOURCE_SYSTEM, src.SOURCE_CUSTOMER_ID, src.NORMALIZED_EMAIL, src.NORMALIZED_PHONE,
            src.NORMALIZED_FIRST_NAME, src.NORMALIZED_LAST_NAME, src.NORMALIZED_FULL_NAME,
            src.DOB, src.NORMALIZED_POSTAL_CODE, src.NORMALIZED_CITY, src.LOYALTY_ID,
            CURRENT_TIMESTAMP()
        )
    """)

    exec_sql(session, f"""
        CREATE OR REPLACE TEMP TABLE TMP_BATCH_KEYS AS
        SELECT c.SOURCE_SYSTEM,
               c.SOURCE_CUSTOMER_ID,
               k.NORMALIZED_EMAIL,
               k.NORMALIZED_PHONE,
               k.LOYALTY_ID,
               k.NORMALIZED_FULL_NAME,
               k.DOB,
               k.NORMALIZED_POSTAL_CODE,
               k.NORMALIZED_CITY
        FROM IDENTITY.SOURCE_CUSTOMER c
        JOIN IDENTITY.SOURCE_CUSTOMER_KEYS k
          ON c.SOURCE_SYSTEM=k.SOURCE_SYSTEM
         AND c.SOURCE_CUSTOMER_ID=k.SOURCE_CUSTOMER_ID
        WHERE c.LAST_SEEN_BATCH_ID='{q(batch_id)}'
          AND c.ACTIVE_FLAG=TRUE
    """)

    exec_sql(session, """
        CREATE OR REPLACE TEMP TABLE TMP_EXISTING_KEYS AS
        SELECT x.GOLDEN_CUSTOMER_ID,
               k.SOURCE_SYSTEM,
               k.SOURCE_CUSTOMER_ID,
               k.NORMALIZED_EMAIL,
               k.NORMALIZED_PHONE,
               k.LOYALTY_ID,
               k.NORMALIZED_FULL_NAME,
               k.DOB,
               k.NORMALIZED_POSTAL_CODE,
               k.NORMALIZED_CITY
        FROM IDENTITY.IDENTITY_CROSSWALK x
        JOIN IDENTITY.SOURCE_CUSTOMER_KEYS k
          ON x.SOURCE_SYSTEM=k.SOURCE_SYSTEM
         AND x.SOURCE_CUSTOMER_ID=k.SOURCE_CUSTOMER_ID
        WHERE x.ACTIVE_FLAG=TRUE
    """)

    exec_sql(session, """
        CREATE OR REPLACE TEMP TABLE TMP_CANDIDATES AS
        SELECT b.SOURCE_SYSTEM,
               b.SOURCE_CUSTOMER_ID,
               e.GOLDEN_CUSTOMER_ID CANDIDATE_GOLDEN_CUSTOMER_ID,
               e.SOURCE_SYSTEM CANDIDATE_SOURCE_SYSTEM,
               e.SOURCE_CUSTOMER_ID CANDIDATE_SOURCE_CUSTOMER_ID,
               b.NORMALIZED_EMAIL B_EMAIL,
               e.NORMALIZED_EMAIL E_EMAIL,
               b.NORMALIZED_PHONE B_PHONE,
               e.NORMALIZED_PHONE E_PHONE,
               b.LOYALTY_ID B_LOYALTY,
               e.LOYALTY_ID E_LOYALTY,
               b.NORMALIZED_FULL_NAME B_NAME,
               e.NORMALIZED_FULL_NAME E_NAME,
               b.DOB B_DOB,
               e.DOB E_DOB,
               b.NORMALIZED_POSTAL_CODE B_ZIP,
               e.NORMALIZED_POSTAL_CODE E_ZIP,
               b.NORMALIZED_CITY B_CITY,
               e.NORMALIZED_CITY E_CITY
        FROM TMP_BATCH_KEYS b
        JOIN TMP_EXISTING_KEYS e
          ON (
                b.LOYALTY_ID IS NOT NULL AND b.LOYALTY_ID=e.LOYALTY_ID
             )
          OR (
                b.NORMALIZED_EMAIL IS NOT NULL AND b.NORMALIZED_EMAIL=e.NORMALIZED_EMAIL
             )
          OR (
                b.NORMALIZED_PHONE IS NOT NULL AND b.NORMALIZED_PHONE=e.NORMALIZED_PHONE
             )
          OR (
                b.DOB IS NOT NULL AND b.DOB=e.DOB
            AND b.NORMALIZED_POSTAL_CODE IS NOT NULL
            AND b.NORMALIZED_POSTAL_CODE=e.NORMALIZED_POSTAL_CODE
             )
          OR (
                b.NORMALIZED_POSTAL_CODE IS NOT NULL
            AND b.NORMALIZED_POSTAL_CODE=e.NORMALIZED_POSTAL_CODE
            AND b.NORMALIZED_CITY IS NOT NULL
            AND b.NORMALIZED_CITY=e.NORMALIZED_CITY
             )
        WHERE NOT (
            b.SOURCE_SYSTEM=e.SOURCE_SYSTEM
            AND b.SOURCE_CUSTOMER_ID=e.SOURCE_CUSTOMER_ID
        )
    """)

    exec_sql(session, """
        CREATE OR REPLACE TEMP TABLE TMP_CANDIDATES_NOT_REJECTED AS
        SELECT c.*
        FROM TMP_CANDIDATES c
        LEFT JOIN IDENTITY.MATCH_REJECTION_REGISTRY r
          ON r.ACTIVE_FLAG=TRUE
         AND c.SOURCE_SYSTEM=r.SOURCE_SYSTEM
         AND c.SOURCE_CUSTOMER_ID=r.SOURCE_CUSTOMER_ID
         AND (
              c.CANDIDATE_GOLDEN_CUSTOMER_ID=r.REJECTED_GOLDEN_CUSTOMER_ID
              OR (
                   c.CANDIDATE_SOURCE_SYSTEM=r.REJECTED_SOURCE_SYSTEM
               AND c.CANDIDATE_SOURCE_CUSTOMER_ID=r.REJECTED_SOURCE_CUSTOMER_ID
              )
         )
        WHERE r.REJECTION_ID IS NULL
    """)

    exec_sql(session, """
        CREATE OR REPLACE TEMP TABLE TMP_SCORED AS
        SELECT *,
               IFF(B_LOYALTY IS NOT NULL AND B_LOYALTY=E_LOYALTY,1,0) LOYALTY_SCORE,
               IFF(B_EMAIL IS NOT NULL AND B_EMAIL=E_EMAIL,1,0) EMAIL_SCORE,
               IFF(B_PHONE IS NOT NULL AND B_PHONE=E_PHONE,1,0) PHONE_SCORE,
               IFF(B_DOB IS NOT NULL AND B_DOB=E_DOB,1,0) DOB_SCORE,
               IFF(B_ZIP IS NOT NULL AND B_ZIP=E_ZIP,1,0) ZIP_SCORE,
               COALESCE(JAROWINKLER_SIMILARITY(B_NAME,E_NAME)/100.0,0) NAME_JW_SCORE,
               IFF(B_NAME IS NOT NULL AND E_NAME IS NOT NULL,
                   IFF(EDITDISTANCE(B_NAME,E_NAME)<=2,1,
                       IFF(EDITDISTANCE(B_NAME,E_NAME)<=4,0.8,0)
                   ),
                   0
               ) NAME_EDIT_SCORE
        FROM TMP_CANDIDATES_NOT_REJECTED
    """)

    exec_sql(session, f"""
        CREATE OR REPLACE TEMP TABLE TMP_BEST_MATCH AS
        SELECT *
        FROM (
            SELECT SOURCE_SYSTEM,
                   SOURCE_CUSTOMER_ID,
                   CANDIDATE_GOLDEN_CUSTOMER_ID,
                   CANDIDATE_SOURCE_SYSTEM,
                   CANDIDATE_SOURCE_CUSTOMER_ID,
                   ROUND(
                        LOYALTY_SCORE * {float(w["LOYALTY_EXACT"])}
                      + EMAIL_SCORE   * {float(w["EMAIL_EXACT"])}
                      + PHONE_SCORE   * {float(w["PHONE_EXACT"])}
                      + DOB_SCORE     * {float(w["DOB_EXACT"])}
                      + ZIP_SCORE     * {float(w["ZIP_EXACT"])}
                      + GREATEST(NAME_JW_SCORE,NAME_EDIT_SCORE) * {float(w["NAME_FUZZY"])},
                      4
                   ) MATCH_SCORE,
                   CASE
                       WHEN LOYALTY_SCORE=1 THEN 'LOYALTY_EXACT'
                       WHEN EMAIL_SCORE=1 THEN 'EMAIL_EXACT'
                       WHEN PHONE_SCORE=1 THEN 'PHONE_EXACT'
                       WHEN DOB_SCORE=1 AND ZIP_SCORE=1 AND GREATEST(NAME_JW_SCORE,NAME_EDIT_SCORE)>=0.90 THEN 'DOB_ZIP_NAME_FUZZY'
                       WHEN GREATEST(NAME_JW_SCORE,NAME_EDIT_SCORE)>=0.92 AND ZIP_SCORE=1 THEN 'NAME_ZIP_FUZZY'
                       ELSE 'WEIGHTED_FUZZY'
                   END MATCH_REASON,
                   ROW_NUMBER() OVER (
                       PARTITION BY SOURCE_SYSTEM, SOURCE_CUSTOMER_ID
                       ORDER BY (
                            LOYALTY_SCORE * {float(w["LOYALTY_EXACT"])}
                          + EMAIL_SCORE   * {float(w["EMAIL_EXACT"])}
                          + PHONE_SCORE   * {float(w["PHONE_EXACT"])}
                          + DOB_SCORE     * {float(w["DOB_EXACT"])}
                          + ZIP_SCORE     * {float(w["ZIP_EXACT"])}
                          + GREATEST(NAME_JW_SCORE,NAME_EDIT_SCORE) * {float(w["NAME_FUZZY"])}
                       ) DESC
                   ) RN
            FROM TMP_SCORED
        )
        WHERE RN=1
    """)

    exec_sql(session, f"""
        CREATE OR REPLACE TEMP TABLE TMP_RESOLVED AS
        SELECT b.SOURCE_SYSTEM,
               b.SOURCE_CUSTOMER_ID,
               CASE
                   WHEN bm.MATCH_SCORE >= {float(cfg["auto_threshold"])} THEN bm.CANDIDATE_GOLDEN_CUSTOMER_ID
                   ELSE UUID_STRING()
               END GOLDEN_CUSTOMER_ID,
               CASE
                   WHEN bm.MATCH_SCORE >= {float(cfg["auto_threshold"])} THEN 'AUTO_MATCH'
                   WHEN bm.MATCH_SCORE >= {float(cfg["review_threshold"])} THEN 'REVIEW'
                   ELSE 'NEW_GOLDEN'
               END RESOLUTION_TYPE,
               bm.CANDIDATE_GOLDEN_CUSTOMER_ID,
               bm.CANDIDATE_SOURCE_SYSTEM,
               bm.CANDIDATE_SOURCE_CUSTOMER_ID,
               COALESCE(bm.MATCH_SCORE,1.0) CONFIDENCE,
               COALESCE(bm.MATCH_REASON,'NO_CANDIDATE') MATCH_REASON,
               '{q(cfg["rule_set_id"])}' RULE_SET_ID,
               {int(cfg["rule_version"])} RULE_VERSION
        FROM TMP_BATCH_KEYS b
        LEFT JOIN TMP_BEST_MATCH bm
          ON b.SOURCE_SYSTEM=bm.SOURCE_SYSTEM
         AND b.SOURCE_CUSTOMER_ID=bm.SOURCE_CUSTOMER_ID
    """)

    exec_sql(session, f"""
        INSERT INTO IDENTITY.STEWARDSHIP_QUEUE (
            BATCH_ID,
            SOURCE_SYSTEM,
            SOURCE_CUSTOMER_ID,
            CANDIDATE_GOLDEN_CUSTOMER_ID,
            CANDIDATE_SOURCE_SYSTEM,
            CANDIDATE_SOURCE_CUSTOMER_ID,
            MATCH_SCORE,
            MATCH_REASON,
            RULE_SET_ID,
            RULE_VERSION,
            STATUS,
            CREATED_AT,
            UPDATED_AT
        )
        SELECT '{q(batch_id)}',
               SOURCE_SYSTEM,
               SOURCE_CUSTOMER_ID,
               CANDIDATE_GOLDEN_CUSTOMER_ID,
               CANDIDATE_SOURCE_SYSTEM,
               CANDIDATE_SOURCE_CUSTOMER_ID,
               CONFIDENCE,
               MATCH_REASON,
               RULE_SET_ID,
               RULE_VERSION,
               'PENDING',
               CURRENT_TIMESTAMP(),
               CURRENT_TIMESTAMP()
        FROM TMP_RESOLVED
        WHERE RESOLUTION_TYPE='REVIEW'
    """)

    exec_sql(session, """
        MERGE INTO GOLD.GOLDEN_CUSTOMER tgt
        USING (
            SELECT r.GOLDEN_CUSTOMER_ID,
                   c.FIRST_NAME,
                   c.LAST_NAME,
                   c.EMAIL,
                   c.PHONE,
                   c.DOB,
                   c.ADDRESS_LINE1,
                   c.CITY,
                   c.STATE,
                   c.POSTAL_CODE,
                   c.COUNTRY
            FROM TMP_RESOLVED r
            JOIN IDENTITY.SOURCE_CUSTOMER c
              ON r.SOURCE_SYSTEM=c.SOURCE_SYSTEM
             AND r.SOURCE_CUSTOMER_ID=c.SOURCE_CUSTOMER_ID
            WHERE r.RESOLUTION_TYPE='NEW_GOLDEN'
        ) src
        ON tgt.GOLDEN_CUSTOMER_ID=src.GOLDEN_CUSTOMER_ID
        WHEN NOT MATCHED THEN INSERT (
            GOLDEN_CUSTOMER_ID, FIRST_NAME, LAST_NAME, EMAIL, PHONE, DOB,
            ADDRESS_LINE1, CITY, STATE, POSTAL_CODE, COUNTRY,
            CREATED_AT, UPDATED_AT, ACTIVE_FLAG
        )
        VALUES (
            src.GOLDEN_CUSTOMER_ID, src.FIRST_NAME, src.LAST_NAME, src.EMAIL, src.PHONE, src.DOB,
            src.ADDRESS_LINE1, src.CITY, src.STATE, src.POSTAL_CODE, src.COUNTRY,
            CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP(), TRUE
        )
    """)

    exec_sql(session, """
        MERGE INTO IDENTITY.IDENTITY_CROSSWALK tgt
        USING (
            SELECT GOLDEN_CUSTOMER_ID,
                   SOURCE_SYSTEM,
                   SOURCE_CUSTOMER_ID,
                   RESOLUTION_TYPE,
                   CONFIDENCE,
                   MATCH_REASON,
                   RULE_SET_ID,
                   RULE_VERSION
            FROM TMP_RESOLVED
            WHERE RESOLUTION_TYPE IN ('AUTO_MATCH','NEW_GOLDEN')
        ) src
        ON tgt.SOURCE_SYSTEM=src.SOURCE_SYSTEM
       AND tgt.SOURCE_CUSTOMER_ID=src.SOURCE_CUSTOMER_ID
        WHEN MATCHED THEN UPDATE SET
            GOLDEN_CUSTOMER_ID=src.GOLDEN_CUSTOMER_ID,
            MATCH_TYPE=src.RESOLUTION_TYPE,
            MATCH_CONFIDENCE=src.CONFIDENCE,
            MATCH_REASON=src.MATCH_REASON,
            RULE_SET_ID=src.RULE_SET_ID,
            RULE_VERSION=src.RULE_VERSION,
            UPDATED_AT=CURRENT_TIMESTAMP(),
            ACTIVE_FLAG=TRUE
        WHEN NOT MATCHED THEN INSERT (
            GOLDEN_CUSTOMER_ID,
            SOURCE_SYSTEM,
            SOURCE_CUSTOMER_ID,
            MATCH_TYPE,
            MATCH_CONFIDENCE,
            MATCH_REASON,
            RULE_SET_ID,
            RULE_VERSION,
            ACTIVE_FLAG,
            CREATED_AT,
            UPDATED_AT
        )
        VALUES (
            src.GOLDEN_CUSTOMER_ID,
            src.SOURCE_SYSTEM,
            src.SOURCE_CUSTOMER_ID,
            src.RESOLUTION_TYPE,
            src.CONFIDENCE,
            src.MATCH_REASON,
            src.RULE_SET_ID,
            src.RULE_VERSION,
            TRUE,
            CURRENT_TIMESTAMP(),
            CURRENT_TIMESTAMP()
        )
    """)

    exec_sql(session, f"""
        INSERT INTO IDENTITY.IDENTITY_EVENT_LOG (
            EVENT_TYPE,
            GOLDEN_CUSTOMER_ID,
            SOURCE_SYSTEM,
            SOURCE_CUSTOMER_ID,
            CANDIDATE_GOLDEN_CUSTOMER_ID,
            CANDIDATE_SOURCE_SYSTEM,
            CANDIDATE_SOURCE_CUSTOMER_ID,
            MATCH_SCORE,
            MATCH_REASON,
            RULE_SET_ID,
            RULE_VERSION,
            OPERATOR,
            REASON,
            PAYLOAD
        )
        SELECT RESOLUTION_TYPE,
               GOLDEN_CUSTOMER_ID,
               SOURCE_SYSTEM,
               SOURCE_CUSTOMER_ID,
               CANDIDATE_GOLDEN_CUSTOMER_ID,
               CANDIDATE_SOURCE_SYSTEM,
               CANDIDATE_SOURCE_CUSTOMER_ID,
               CONFIDENCE,
               MATCH_REASON,
               RULE_SET_ID,
               RULE_VERSION,
               'SYSTEM',
               'rule-driven matcher',
               OBJECT_CONSTRUCT(
                   'batch_id','{q(batch_id)}',
                   'auto_threshold',{float(cfg["auto_threshold"])},
                   'review_threshold',{float(cfg["review_threshold"])}
               )
        FROM TMP_RESOLVED
    """)

    exec_sql(session, f"""
        UPDATE {raw_table}
        SET PROCESS_STATUS='COMPLETE',
            PROCESSED_AT=CURRENT_TIMESTAMP(),
            ERROR_MESSAGE=NULL
        WHERE BATCH_ID='{q(batch_id)}'
          AND PROCESS_STATUS IN ('NEW','LOADED','PROCESSING')
    """)

    mark_batch(session, batch_id, "COMPLETE")

    counts = session.sql("""
        SELECT COUNT_IF(RESOLUTION_TYPE='AUTO_MATCH') AUTO_MATCHES,
               COUNT_IF(RESOLUTION_TYPE='REVIEW') REVIEWS,
               COUNT_IF(RESOLUTION_TYPE='NEW_GOLDEN') NEW_GOLDENS
        FROM TMP_RESOLVED
    """).collect()[0].as_dict()

    return {
        "batch_id": batch_id,
        "source_system": source_system,
        "status": "COMPLETE",
        "auto_matches": counts.get("AUTO_MATCHES", 0),
        "reviews": counts.get("REVIEWS", 0),
        "new_goldens": counts.get("NEW_GOLDENS", 0)
    }

def refresh_profile(session):
    exec_sql(session, """
        CREATE OR REPLACE TABLE GOLD.GOLDEN_CUSTOMER_PROFILE AS
        SELECT g.GOLDEN_CUSTOMER_ID,
               g.FIRST_NAME,
               g.LAST_NAME,
               g.EMAIL,
               g.PHONE,
               g.DOB,
               g.CITY,
               g.STATE,
               g.COUNTRY,
               ARRAY_AGG(DISTINCT x.SOURCE_SYSTEM || ':' || x.SOURCE_CUSTOMER_ID) LINKED_SOURCE_KEYS,
               ARRAY_AGG(DISTINCT x.SOURCE_SYSTEM) LINKED_SOURCE_SYSTEMS,
               COUNT(DISTINCT x.SOURCE_SYSTEM || ':' || x.SOURCE_CUSTOMER_ID) LINKED_SOURCE_RECORD_COUNT,
               CURRENT_TIMESTAMP() REFRESHED_AT
        FROM GOLD.GOLDEN_CUSTOMER g
        LEFT JOIN IDENTITY.IDENTITY_CROSSWALK x
          ON g.GOLDEN_CUSTOMER_ID=x.GOLDEN_CUSTOMER_ID
         AND COALESCE(x.ACTIVE_FLAG, TRUE)=TRUE
        GROUP BY g.GOLDEN_CUSTOMER_ID,
                 g.FIRST_NAME,
                 g.LAST_NAME,
                 g.EMAIL,
                 g.PHONE,
                 g.DOB,
                 g.CITY,
                 g.STATE,
                 g.COUNTRY
    """)

def main(session: Session, max_batches: int = 10):
    ensure_objects(session)
    cfg = get_rule_config(session)
    batches = get_batches(session, max_batches)

    results = []
    for batch in batches:
        try:
            results.append(process_batch(session, batch, cfg))
        except Exception as e:
            mark_batch(session, batch["BATCH_ID"], "ERROR", str(e)[:1500])
            results.append({
                "batch_id": batch["BATCH_ID"],
                "source_system": batch["SOURCE_SYSTEM"],
                "status": "ERROR",
                "error": str(e)[:1500]
            })

    refresh_profile(session)

    return {
        "version": "RULE_DRIVEN_MATCHER_V1",
        "completed_at_utc": datetime.utcnow().isoformat(),
        "batches_found": len(batches),
        "rule_set_id": cfg["rule_set_id"],
        "rule_version": cfg["rule_version"],
        "auto_threshold": cfg["auto_threshold"],
        "review_threshold": cfg["review_threshold"],
        "weights": cfg["weights"],
        "results": results
    }
$$;